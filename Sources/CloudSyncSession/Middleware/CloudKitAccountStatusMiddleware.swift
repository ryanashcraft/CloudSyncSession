import CloudKit
import os.log

public struct CloudKitAccountStatusMiddleware: Middleware {
    public var session: CloudSyncSession
    let ckContainer: CKContainer

    private let log = OSLog(
        subsystem: "com.algebraiclabs.CloudSyncSession",
        category: "account status middleware"
    )

    public init(session: CloudSyncSession, ckContainer: CKContainer) {
        self.session = session
        self.ckContainer = ckContainer
    }

    public func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        switch event {
        case .start:
            ckContainer.accountStatus { status, error in
                if let error = error {
                    os_log("Failed to fetch account status: %{public}@", log: self.log, type: .error, String(describing: error))
                }

                self.session.dispatch(event: .accountStatusChanged(status))
            }
        default:
            break
        }

        return next(event)
    }
}
