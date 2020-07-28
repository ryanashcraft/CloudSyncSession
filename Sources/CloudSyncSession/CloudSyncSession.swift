import CloudKit
import CloudKitCodable
import os.log

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

    var logDescription: String {
        switch self {
        case .accountStatusChanged:
            return "account status changed"
        case .modify:
            return "modify"
        case .continue:
            return "continue"
        case .halt:
            return "halt"
        case .backoff:
            return "backoff"
        case .createZone:
            return "create zone"
        case .retry:
            return "retry"
        case .splitThenRetry:
            return "split then retry"
        case .conflict:
            return "conflict"
        case .partialFailure:
            return "partial failure"
        }
    }

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

typealias Next = (SyncEvent) -> SyncEvent

struct AnyMiddleware<MO: ModifyOperation>: Middleware {
    init<M: Middleware>(value: M) where M.MO == MO {
        self.session = value.session
        self.run = value.run
    }

    var session: CloudSyncSession<MO>
    var run: (_ next: Next, _ event: SyncEvent) -> SyncEvent

    func run(next: Next, event: SyncEvent) -> SyncEvent {
        run(next, event)
    }
}

protocol Middleware {
    associatedtype MO: ModifyOperation

    var session: CloudSyncSession<MO> { get }

    func eraseToAnyMiddleware() -> AnyMiddleware<MO>
    func run(next: Next, event: SyncEvent) -> SyncEvent
}

extension Middleware {
    func eraseToAnyMiddleware() -> AnyMiddleware<MO> {
        return AnyMiddleware(value: self)
    }
}

struct TickMiddleware<MO: ModifyOperation>: Middleware {
    var session: CloudSyncSession<MO>

    func run(next: Next, event: SyncEvent) -> SyncEvent {
        switch event {
        case .modify:
            let newEvent = next(event)

            tick()

            return newEvent
        default:
            return next(event)
        }
    }

    private func tick() {
        if let work = session.state.currentWork {
            switch work {
            case .push(let operation):
                session.operationHandler.handle(modifyOperation: operation) { result in
                    switch result {
                    case .success(let records):
                        session.dispatch(event: .continue)
                        session.onRecordsModified?(records)
                    case .failure(let error):
                        if let event = SyncEvent(error: error) {
                            session.dispatch(event: event)
                        }
                    }
                }
            }
        }
    }
}

struct LoggerMiddleware<MO: ModifyOperation>: Middleware {
    var session: CloudSyncSession<MO>

    var log = OSLog(
        subsystem: "com.algebraiclabs.CloudSyncSession",
        category: "event"
    )

    func run(next: Next, event: SyncEvent) -> SyncEvent {
        os_log("%{public}@", log: log, type: .debug, event.logDescription)

        return next(event)
    }
}

class CloudSyncSession<MO: ModifyOperation> {
    @Published var state: SyncState<MO>
    let operationHandler: OperationHandler
    var onRecordsModified: (([CKRecord]) -> Void)?

    var middlewares = [AnyMiddleware<MO>]()

    init(initialState: SyncState<MO> = SyncState<MO>(isHalted: true), operationHandler: OperationHandler) {
        self.state = initialState
        self.operationHandler = operationHandler

        self.middlewares = [
            LoggerMiddleware<MO>(session: self).eraseToAnyMiddleware(),
            TickMiddleware<MO>(session: self).eraseToAnyMiddleware(),
        ]
    }

    func dispatch(event: SyncEvent) {
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
}
