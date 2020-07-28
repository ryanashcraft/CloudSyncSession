import CloudKit
import CloudKitCodable

protocol ModifyOperation {
    var records: [CKRecord] { get set }

    init()
}

extension ModifyOperation {
    init(records: [CKRecord]) {
        self.init()
        self.records = records
    }
}

protocol OperationHandler {
    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<[CKRecord], Error>) -> Void)
}

extension CKModifyRecordsOperation: ModifyOperation {
    convenience init(records: [CKRecord]) {
        self.init(recordsToSave: records, recordIDsToDelete: [])
    }

    var records: [CKRecord] {
        get {
            self.recordsToSave ?? []
        }
        set {
            self.recordsToSave = newValue
        }
    }
}

enum SyncWork {
    case push(ModifyOperation)
}

typealias Dispatch = (SyncEvent) -> Void

struct SyncState<MO: ModifyOperation> {
    var isHalted: Bool
    var workQueue = [SyncWork]()
    var currentWork: SyncWork?

    func reduce(event: SyncEvent) -> SyncState {
        var state = self

        switch event {
        case .accountStatusChanged(let accountStatus):
            switch accountStatus {
            case .available:
                state.isHalted = false
            default:
                state.isHalted = true
            }
        case .modify(let records):
            guard !state.isHalted else {
                return state
            }

            let work = SyncWork.push(MO(records: records))

            if state.currentWork == nil {
                state.currentWork = work
            } else {
                state.workQueue.append(work)
            }
        case .continue:
            state.currentWork = nil
        case .halt:
            state.isHalted = true
        default:
            break
        }

        return state
    }
}

enum SyncEvent {
    case accountStatusChanged(CKAccountStatus)
    case modify([CKRecord])
    case `continue`
    case halt
    case backoff
    case createZone
    case retry
    case splitThenRetry
    case conflict
    case partialFailure

    init?(error: Error) {
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
                 .changeTokenExpired:
                self = .halt
            case .internalError,
                 .networkUnavailable,
                 .networkFailure,
                 .serviceUnavailable,
                 .zoneBusy,
                 .requestRateLimited:
                self = .backoff
            case .serverResponseLost:
                self = .retry
            case .partialFailure, .batchRequestFailed:
                self = .partialFailure
            case .serverRecordChanged:
                self = .conflict
            case .limitExceeded:
                self = .splitThenRetry
            case .zoneNotFound, .userDeletedZone:
                self = .createZone
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
            self = .halt
        }
    }
}

class CloudSyncSession<MO: ModifyOperation> {
    @Published var state: SyncState<MO>
    let operationHandler: OperationHandler
    var onRecordsModified: (([CKRecord]) -> Void)?

    init(initialState: SyncState<MO> = SyncState<MO>(isHalted: true), operationHandler: OperationHandler) {
        self.state = initialState
        self.operationHandler = operationHandler
    }

    func dispatch(event: SyncEvent) {
        state = state.reduce(event: event)

        switch event {
        case .modify:
            tick()
        default:
            break
        }
    }

    private func tick() {
        if let work = state.currentWork {
            switch work {
            case .push(let operation):
                operationHandler.handle(modifyOperation: operation) { result in
                    switch result {
                    case .success(let records):
                        self.dispatch(event: .continue)
                        self.onRecordsModified?(records)
                    case .failure(let error):
                        if let event = SyncEvent(error: error) {
                            self.dispatch(event: event)
                        }
                    }
                }
            }
        }
    }
}
