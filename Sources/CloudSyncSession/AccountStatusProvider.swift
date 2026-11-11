import CloudKit

/// Looks up the current iCloud account status. The session calls it from `start()` whenever it
/// does not know the status, which is the case for a new session and after `reset()`.
public typealias AccountStatusProvider = @Sendable () async -> CKAccountStatus

public extension CloudSyncSession {
    /// An account status provider that asks the given CloudKit container.
    static func accountStatusProvider(for container: CKContainer) -> AccountStatusProvider {
        {
            await withCheckedContinuation { continuation in
                container.accountStatus { status, error in
                    if let error {
                        Log.session.error("Failed to fetch account status: \(String(describing: error))")
                    }

                    continuation.resume(returning: status)
                }
            }
        }
    }
}
