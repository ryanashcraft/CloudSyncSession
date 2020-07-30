import CloudKit
import os.log

public class CloudSyncSession {
    @PublishedAfter var state: SyncState = SyncState()

    let operationHandler: OperationHandler
    let zoneIdentifier: CKRecordZone.ID

    private var middlewares = [AnyMiddleware]()

    public var onRecordsModified: (([CKRecord], [CKRecord.ID]) -> Void)?
    public var onFetchCompleted: ((CKServerChangeToken?, [CKRecord], [CKRecord.ID]) -> Void)?
    public var resolveConflict: ((CKRecord, CKRecord) -> CKRecord?)?

    var dispatchQueue = DispatchQueue(label: "CloudSyncSession.Dispatch", qos: .userInitiated)

    public init(operationHandler: OperationHandler, zoneIdentifier: CKRecordZone.ID) {
        self.operationHandler = operationHandler
        self.zoneIdentifier = zoneIdentifier

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
