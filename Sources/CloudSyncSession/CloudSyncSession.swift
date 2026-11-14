import CloudKit
import SyncSessionCore

public typealias ConflictResolver = (CKRecord, CKRecord) -> CKRecord?
public typealias ChangeTokenExpiredResolver = () -> CKServerChangeToken?

/// An object that manages a long-lived series of CloudKit syncing operations.
///
/// The session itself, with its queues and the run loop that works through them, is
/// `SyncSession` in SyncSessionCore and knows nothing about CloudKit. This class supplies the
/// CloudKit side: it has an `OperationHandler` carry out each piece of work, and it decides what
/// to do about each CloudKit error with `FailureResolver`.
///
/// It adds no mutable state of its own, so it is as safe to share across threads as its superclass.
public class CloudSyncSession: SyncSession<CloudKitBackend>, @unchecked Sendable {
    /// Handles fetch, modify, create zone, and create subscription operations.
    let operationHandler: OperationHandler

    /// The CloudKit zone ID.
    let zoneID: CKRecordZone.ID

    /// The function handler that will be called to resolve record conflicts.
    public let resolveConflict: ConflictResolver?

    /// The function handler that will be called when the change token should be expired.
    public let resolveExpiredChangeToken: ChangeTokenExpiredResolver?

    /**
     Creates a session.

     - Parameter operationHandler: The object that handles fetch, modify, create zone, and create subscription operations.
     - Parameter zoneID: The CloudKit zone ID.
     - Parameter accountStatusProvider: Looks up the iCloud account status. Called from `start()` whenever the status is not known. Without one, the app must call `accountStatusChanged(_:)` itself before any work can run.
     - Parameter resolveConflict: The function handler that will be called to resolve record conflicts.
     - Parameter resolveExpiredChangeToken: The function handler that will be called when the change token should be expired.
     - Parameter pacing: How the session waits. Tests pass their own so that they do not wait in real time.
     */
    public init(
        operationHandler: OperationHandler,
        zoneID: CKRecordZone.ID,
        accountStatusProvider: AccountStatusProvider? = nil,
        resolveConflict: @escaping ConflictResolver,
        resolveExpiredChangeToken: @escaping ChangeTokenExpiredResolver,
        pacing: Pacing = .live
    ) {
        self.operationHandler = operationHandler
        self.zoneID = zoneID
        self.resolveConflict = resolveConflict
        self.resolveExpiredChangeToken = resolveExpiredChangeToken

        let failureResolver = FailureResolver(
            resolveConflict: resolveConflict,
            resolveExpiredChangeToken: resolveExpiredChangeToken
        )

        super.init(
            perform: { work in
                await carryOut(work, with: operationHandler, zoneID: zoneID)
            },
            resolveFailure: { error, work in
                failureResolver.resolution(for: error, work: work)
            },
            accountStatusProvider: accountStatusProvider,
            pacing: pacing
        )
    }
}

/// Hands one piece of work to the handler and waits for its result.
private func carryOut(
    _ work: SyncWork,
    with operationHandler: OperationHandler,
    zoneID: CKRecordZone.ID
) async -> Result<SyncWork.Result, Error> {
    do {
        switch work {
        case let .fetch(operation):
            return .success(.fetch(try await operationHandler.handle(fetchOperation: operation)))
        case let .modify(operation):
            return .success(.modify(try await operationHandler.handle(modifyOperation: operation)))
        case let .setup(operation):
            switch operation.step {
            case .zone:
                return .success(.setup(try await operationHandler.handle(createZoneOperation: CreateZoneOperation(zoneID: zoneID))))
            case .subscription:
                return .success(.setup(try await operationHandler.handle(createSubscriptionOperation: CreateSubscriptionOperation(zoneID: zoneID))))
            }
        }
    } catch {
        return .failure(error)
    }
}
