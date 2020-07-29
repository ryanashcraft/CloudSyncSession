import CloudKit
import CloudKitCodable
import os.log

enum SyncWork {
    case push(ModifyOperation)
}

typealias Dispatch = (SyncEvent) -> Void

struct SyncState {
    var workQueue = [SyncWork]()

    var hasGoodAccountStatus: Bool? = nil
    var hasHalted: Bool = false

    var isRunning: Bool {
        (hasGoodAccountStatus ?? false) && !hasHalted
    }

    var currentWork: SyncWork? {
        isRunning ? workQueue.first : nil
    }

    func reduce(event: SyncEvent) -> SyncState {
        var state = self

        switch event {
        case .accountStatusChanged(let accountStatus):
            switch accountStatus {
            case .available:
                state.hasGoodAccountStatus = true
            default:
                state.hasGoodAccountStatus = false
            }
        case .modify(let records):
            let work = SyncWork.push(ModifyOperation(records: records))

            state.workQueue.append(work)
        case .resolveConflict(let records):
            let work = SyncWork.push(ModifyOperation(records: records))

            if !state.workQueue.isEmpty {
                state.workQueue[0] = work
            }
        case .continue:
            if !state.workQueue.isEmpty {
                state.workQueue.removeFirst()
            }
        case .halt:
            state.hasHalted = true
        default:
            break
        }

        return state
    }
}

public class CloudSyncSession {
    @PublishedAfter var state: SyncState = SyncState()

    let operationHandler: OperationHandler

    private var middlewares = [AnyMiddleware]()

    public var onRecordsModified: (([CKRecord]) -> Void)?

    public var resolveConflict: ((CKRecord, CKRecord) -> CKRecord?)?

    private var log = OSLog(
        subsystem: "com.algebraiclabs.CloudSyncSession",
        category: "cloud sync error"
    )

    public init(operationHandler: OperationHandler) {
        self.operationHandler = operationHandler

        self.middlewares = [
            LoggerMiddleware(session: self).eraseToAnyMiddleware(),
            WorkMiddleware(session: self).eraseToAnyMiddleware(),
        ]
    }

    public func dispatch(event: SyncEvent) {
        var middlewaresToRun = Array(self.middlewares.reversed())

        func next(event: SyncEvent) -> SyncEvent {
            if let middleware = middlewaresToRun.popLast() {
                return middleware.run(next: next, event: event)
            } else {
                state = state.reduce(event: event)

                return event
            }
        }

        _ = next(event: event)
    }

    public func appendMiddleware<M: Middleware>(_ middleware: M) {
        middlewares.append(middleware.eraseToAnyMiddleware())
    }

    func logError(_ error: Error) {
        os_log("%{public}@", log: log, type: .error, error.localizedDescription)
    }

    func mapErrorToEvent(error: Error, work: SyncWork) -> SyncEvent? {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated,
                 .managedAccountRestricted,
                 .quotaExceeded,
                 .badDatabase,
                 .incompatibleVersion,
                 .permissionFailure,
                 .missingEntitlement,
                 .badContainer,
                 .constraintViolation,
                 .referenceViolation,
                 .invalidArguments,
                 .serverRejectedRequest,
                 .resultsTruncated,
                 .changeTokenExpired,
                 .batchRequestFailed:
                return .halt
            case .internalError,
                 .networkUnavailable,
                 .networkFailure,
                 .serviceUnavailable,
                 .zoneBusy,
                 .requestRateLimited:
                return .backoff
            case .serverResponseLost:
                return .retry
            case .partialFailure:
                guard let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID: Error] else {
                    return .halt
                }

                guard case let .push(operation) = work else {
                    return .halt
                }

                let recordIDsNotSavedOrDeleted = partialErrors.keys

                let batchRequestFailedRecordIDs = partialErrors.filter({ (_, error) in
                    if let error = error as? CKError, error.code == .batchRequestFailed {
                        return true
                    }

                    return false
                }).keys

                let serverRecordChangedErrors = partialErrors.filter({ (_, error) in
                    if let error = error as? CKError, error.code == .serverRecordChanged {
                        return true
                    }

                    return false
                }).values

                let resolvedConflictsToSave = serverRecordChangedErrors.compactMap { error in
                    self.resolveConflict(error: error)
                }

                if resolvedConflictsToSave.count != serverRecordChangedErrors.count {
                    // If couldn't handle conflict for some of the records, abort
                    return .halt
                }

                let batchRequestRecordsToSave = operation.records.filter { record in
                    !resolvedConflictsToSave.map { $0.recordID }.contains(record.recordID)
                        && batchRequestFailedRecordIDs.contains(record.recordID)
                }
                //                    let failedRecordIDsToDelete = recordIDsToDelete.filter(recordIDsNotSavedOrDeleted.contains)

                let allResolvedRecordsToSave = batchRequestRecordsToSave + resolvedConflictsToSave

                guard !allResolvedRecordsToSave.isEmpty else {
                    return nil
                }

                return .resolveConflict(allResolvedRecordsToSave)
            case .serverRecordChanged:
                return .conflict
            case .limitExceeded:
                return .splitThenRetry
            case .zoneNotFound, .userDeletedZone:
                return .createZone
            case .assetNotAvailable,
                 .assetFileNotFound,
                 .assetFileModified,
                 .participantMayNeedVerification,
                 .alreadyShared,
                 .tooManyParticipants,
                 .unknownItem,
                 .operationCancelled:
                return nil
            @unknown default:
                return nil
            }
        } else {
            return .halt
        }
    }

    func resolveConflict(error: Error) -> CKRecord? {
        guard let effectiveError = error as? CKError else {
            os_log(
                "resolveConflict called on an error that was not a CKError. The error was %{public}@",
                log: log,
                type: .fault,
                String(describing: self))


            return nil
        }

        guard effectiveError.code == .serverRecordChanged else {
            os_log(
                "resolveConflict called on a CKError that was not a serverRecordChanged error. The error was %{public}@",
                log: log,
                type: .fault,
                String(describing: effectiveError))

            return nil
        }

        guard let clientRecord = effectiveError.clientRecord else {
            os_log(
                "Failed to obtain client record from serverRecordChanged error. The error was %{public}@",
                log: log,
                type: .fault,
                String(describing: effectiveError))

            return nil
        }

        guard let serverRecord = effectiveError.serverRecord else {
            os_log(
                "Failed to obtain server record from serverRecordChanged error. The error was %{public}@",
                log: log,
                type: .fault,
                String(describing: effectiveError))

            return nil
        }

        os_log(
            "CloudKit conflict with record of type %{public}@. Running conflict resolver", log: log,
            type: .error, serverRecord.recordType)

        guard let resolveConflict = self.resolveConflict else {
            return nil
        }

        guard let resolvedRecord = resolveConflict(clientRecord, serverRecord) else {
            return nil
        }

        // Always return the server record so we don't end up in a conflict loop (the server record has the change tag we want to use)
        // https://developer.apple.com/documentation/cloudkit/ckerror/2325208-serverrecordchanged
        resolvedRecord.allKeys().forEach { serverRecord[$0] = resolvedRecord[$0] }

        return serverRecord
    }
}
