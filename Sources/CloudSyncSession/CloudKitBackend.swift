import CloudKit

// Re-exported so that an app importing CloudSyncSession can use what the session is made of,
// such as `Pacing` and the members of its state and events, without importing the core as well.
@_exported import SyncSessionCore

public let maxRecommendedRecordsPerOperation = 400
public let maxRecommendedRecordsPerFetchOperation = 400

/// CloudKit, as the session's backend: the types it trades in and what has to exist in the
/// database before records can be synced.
public enum CloudKitBackend: SyncBackend {
    public typealias Record = CKRecord
    public typealias RecordID = CKRecord.ID
    public typealias ChangeToken = CKServerChangeToken
    public typealias AccountStatus = CKAccountStatus

    public enum SetupStep: Hashable, Sendable {
        /// The record zone the session syncs.
        case zone

        /// The subscription that has CloudKit notify the app of changes to the zone.
        case subscription
    }

    public static let setupSteps: [SetupStep] = [.zone, .subscription]

    public static var maxItemsPerModify: Int {
        maxRecommendedRecordsPerOperation
    }

    public static let logSubsystem = "com.algebraiclabs.cloud-sync-session"

    public static func isAvailable(_ status: CKAccountStatus) -> Bool {
        status == .available
    }

    public static func makeStopError() -> Error {
        StopError()
    }

    public static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return "Available"
        case .couldNotDetermine:
            return "Could Not Determine"
        case .noAccount:
            return "No Account"
        case .restricted:
            return "Restricted"
        case .temporarilyUnavailable:
            return "Temporarily Unavailable"
        @unknown default:
            return "Unknown"
        }
    }

    public static func describe(_ step: SetupStep) -> String {
        switch step {
        case .zone:
            return "zone"
        case .subscription:
            return "subscription"
        }
    }
}

/// The error the session reports when it is halted by `stop()` rather than by a failure.
public struct StopError: Error {}

// MARK: The session's types, for CloudKit

/// The state of a session.
public typealias SyncState = SessionState<CloudKitBackend>

/// Something the session did or was asked to do, published once on `eventsPublisher` for
/// diagnostics. Events describe what happened; they do not drive the session.
public typealias SyncEvent = SessionEvent<CloudKitBackend>

public typealias SyncWork = SessionWork<CloudKitBackend>
public typealias FetchOperation = SessionFetchOperation<CloudKitBackend>
public typealias ModifyOperation = SessionModifyOperation<CloudKitBackend>

public extension SessionState where Backend == CloudKitBackend {
    /// Indicates whether the zone has been created. The value is nil if the session has yet to create the zone.
    var hasCreatedZone: Bool? {
        setupResults[.zone]
    }

    /// Indicates whether the subscription has been created. The value is nil if the session has yet to create the subscription.
    var hasCreatedSubscription: Bool? {
        setupResults[.subscription]
    }
}

// MARK: Setup, as the operation handler sees it

public struct CreateZoneOperation: Identifiable {
    var zoneID: CKRecordZone.ID

    public let id = UUID()

    public init(zoneID: CKRecordZone.ID) {
        self.zoneID = zoneID
    }
}

public struct CreateSubscriptionOperation: Identifiable {
    var zoneID: CKRecordZone.ID

    public let id = UUID()

    public init(zoneID: CKRecordZone.ID) {
        self.zoneID = zoneID
    }
}
