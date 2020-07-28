import CloudKit

public struct CloudKitAccountStatusMiddleware: Middleware {
    public var session: CloudSyncSession
    var ckContainer: CKContainer

    public init(session: CloudSyncSession, ckContainer: CKContainer) {
        self.session = session
        self.ckContainer = ckContainer
    }

    public func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        switch event {
        case .start:
            ckContainer.accountStatus { status, error in
                if let error = error {
                    session.logError(error)
                }

                self.session.dispatch(event: .accountStatusChanged(status))
            }
        default:
            break
        }

        return next(event)
    }
}
