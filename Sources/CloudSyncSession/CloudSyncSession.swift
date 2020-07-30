import CloudKit
import os.log

public enum SyncWork {
    case push(ModifyOperation)
    case pull(FetchOperation)
    case createZone(CreateZoneOperation)
}

typealias Dispatch = (SyncEvent) -> Void

struct SyncState {
    var workQueue = [SyncWork]()
    var hasGoodAccountStatus: Bool? = nil
    var hasCreatedZone: Bool? = nil
    var isPaued: Bool = false
    var hasHalted: Bool = false
    var changeToken: CKServerChangeToken?

    var isRunning: Bool {
        (hasGoodAccountStatus ?? false) && (hasCreatedZone ?? false) && !hasHalted
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
        case .zoneStatusChanged(let hasCreatedZone):
            state.hasCreatedZone = hasCreatedZone
        case .createZoneCompleted:
            state.hasCreatedZone = true
        case .modify(let records):
            let work = SyncWork.push(ModifyOperation(records: records))

            state.workQueue.append(work)
        case .resolveConflict(let records):
            let work = SyncWork.push(ModifyOperation(records: records))

            if !state.workQueue.isEmpty {
                state.workQueue[0] = work
            }
        case .fetchCompleted, .modifyCompleted:
            if !state.workQueue.isEmpty {
                state.workQueue.removeFirst()
            }
        case .halt:
            state.hasHalted = true
        case .setChangeToken(let changeToken):
            state.changeToken = changeToken
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
    public var onChangeTokenChanged: ((CKServerChangeToken?) -> Void)?

    public var resolveConflict: ((CKRecord, CKRecord) -> CKRecord?)?

    var dispatchQueue = DispatchQueue(label: "CloudSyncSession.Dispatch", qos: .userInitiated)

    public init(operationHandler: OperationHandler) {
        self.operationHandler = operationHandler

        self.middlewares = [
            ErrorMiddleware(session: self).eraseToAnyMiddleware(),
            WorkMiddleware(session: self).eraseToAnyMiddleware(),
            CallbackMiddleware(session: self).eraseToAnyMiddleware(),
            LoggerMiddleware(session: self).eraseToAnyMiddleware(),
        ]
    }

    public func dispatch(event: SyncEvent) {
        dispatchQueue.async {
            var middlewaresToRun = Array(self.middlewares.reversed())

            func next(event: SyncEvent) -> SyncEvent {
                if let middleware = middlewaresToRun.popLast() {
                    return middleware.run(next: next, event: event)
                } else {
                    self.state = self.state.reduce(event: event)

                    return event
                }
            }

            _ = next(event: event)
        }
    }

    public func appendMiddleware<M: Middleware>(_ middleware: M) {
        middlewares.append(middleware.eraseToAnyMiddleware())
    }
}
