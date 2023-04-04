import CloudKit

public enum SyncEvent {
    /// Should be dispatched when the session starts.
    case start

    /// Indicates a non-recoverable er  ror has occured and we should halt.
    case halt(Error)

    /// Indicates the iCloud account status changed.
    case accountStatusChanged(CKAccountStatus)

    /// Queues up work.
    case doWork(SyncWork)

    /// Queues up work that has failed and will be retried.
    case retryWork(SyncWork)

    /// Indicates that work has failed.
    case workFailure(SyncWork, Error)

    /// Indicates that work has succeeded.
    case workSuccess(SyncWork, SyncWork.Result)

    /// Queues up modification work after the work had previously failed due to a conflict.
    /// Includes failed work, records to save including resolved records, and record IDs that should be deleted.
    case resolveConflict(SyncWork, [CKRecord], [CKRecord.ID])

    /// Indicates that work should be retried after some time.
    case retry(SyncWork, Error, TimeInterval?)

    /// Indicates that work should be split up.
    case split(SyncWork, Error)

    /// Does nothing.
    case noop

    var logDescription: String {
        switch self {
        case .start:
            return "Start"
        case .halt:
            return "Halt"
        case let .accountStatusChanged(status):
            return "Account status changed: \(status.debugDescription)"
        case let .doWork(work):
            return "Do work: \(work.debugDescription)"
        case let .retryWork(work):
            return "Retry work: \(work.debugDescription)"
        case let .workFailure(work, _):
            return "Work failure: \(work.debugDescription)"
        case let .workSuccess(work, _):
            return "Work success: \(work.debugDescription)"
        case .retry:
            return "Retry"
        case let .split(work, _):
            return "Split work: \(work.debugDescription)"
        case let .resolveConflict(_, records, recordIDsToDelete):
            return "Resolving \(records.count) records with \(recordIDsToDelete.count) deleted"
        case .noop:
            return "Noop"
        }
    }
}

private extension CKAccountStatus {
    var debugDescription: String {
        switch self {
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
}
