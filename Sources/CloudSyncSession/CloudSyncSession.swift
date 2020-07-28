import CloudKit
import CloudKitCodable
import os.log

enum SyncWork {
    case push(ModifyOperation)
}

typealias Dispatch = (SyncEvent) -> Void

struct SyncState {
    var workQueue = [SyncWork]()
    var currentWork: SyncWork?

    var hasGoodAccountStatus: Bool? = nil
    var hasHalted: Bool = false

    var isRunning: Bool {
        (hasGoodAccountStatus ?? false) && !hasHalted
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
            guard state.isRunning else {
                return state
            }

            let work = SyncWork.push(ModifyOperation(records: records))

            if state.currentWork == nil {
                state.currentWork = work
            } else {
                state.workQueue.append(work)
            }
        case .continue:
            state.currentWork = nil
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
    var onRecordsModified: (([CKRecord]) -> Void)?

    var middlewares = [AnyMiddleware]()

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
}
