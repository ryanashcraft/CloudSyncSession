import CloudKit
import os.log

public struct AccountStatusMiddleware: Middleware {
    public var session: CloudSyncSession
    let ckContainer: CKContainer

    private let log = OSLog(
        subsystem: "com.algebraiclabs.CloudSyncSession",
        category: "Account Status Middleware"
    )

    public init(session: CloudSyncSession, ckContainer: CKContainer) {
        self.session = session
        self.ckContainer = ckContainer
    }

    public func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        switch event {
        case .start:
            if session.state.hasGoodAccountStatus == nil {
                ckContainer.accountStatus { status, error in
                    if let error = error {
                        os_log("Failed to fetch account status: %{public}@", log: self.log, type: .error, String(describing: error))
                    }

                    self.session.dispatch(event: .accountStatusChanged(status))
                }
            }
        default:
            break
        }

        return next(event)
    }
}
