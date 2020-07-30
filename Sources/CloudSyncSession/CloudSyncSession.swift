import CloudKit
import os.log

enum SyncWork {
    case modify(ModifyOperation)
    case fetch(FetchOperation)
    case createZone(CreateZoneOperation)
}

typealias Dispatch = (SyncEvent) -> Void

struct SyncState {
    enum OperationMode {
        case modify
        case fetch
        case createZone
    }

    var modifyQueue = [ModifyOperation]()
    var fetchQueue = [FetchOperation]()
    var createZoneQueue = [CreateZoneOperation]()
    var hasGoodAccountStatus: Bool? = nil
    var hasCreatedZone: Bool? = nil
    var isPaused: Bool = false
    var hasHalted: Bool = false

    var operationMode: OperationMode = .modify

    var isRunning: Bool {
        (hasGoodAccountStatus ?? false) && (hasCreatedZone ?? false) && !hasHalted && !isPaused
    }

    var currentWork: SyncWork? {
        guard isRunning else {
            return nil
        }

        switch operationMode {
        case .modify:
            if let operation = modifyQueue.first {
                return SyncWork.modify(operation)
            }
        case .fetch:
            if let operation = fetchQueue.first {
                return SyncWork.fetch(operation)
            }
        case .createZone:
            if let operation = createZoneQueue.first {
                return SyncWork.createZone(operation)
            }
        }

        return nil
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
            let operation = ModifyOperation(records: records)

            state.modifyQueue.append(operation)
        case .resolveConflict(let records):
            let operation = ModifyOperation(records: records)

            if !state.modifyQueue.isEmpty {
                state.modifyQueue[0] = operation
            }
        case .modifyCompleted:
            if !state.modifyQueue.isEmpty {
                state.modifyQueue.removeFirst()
            }
        case .fetchCompleted:
            if !state.fetchQueue.isEmpty {
                state.fetchQueue.removeFirst()
            }
        case .halt:
            state.hasHalted = true
        case .retry:
            state.isPaused = true
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

    public var onRecordsModified: (([CKRecord], [CKRecord.ID]) -> Void)?
    public var onFetchCompleted: ((CKServerChangeToken?, [CKRecord], [CKRecord.ID]) -> Void)?
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
