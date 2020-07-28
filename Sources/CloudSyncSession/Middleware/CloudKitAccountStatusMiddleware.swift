import CloudKit

public struct CloudKitAccountStatusMiddleware: Middleware {
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        return next(event)
    }
}
