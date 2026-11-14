import Foundation

/// Something the session did or was asked to do, published once on `eventsPublisher` for
/// diagnostics. Events describe what happened; they do not drive the session.
public enum SessionEvent<Backend: SyncBackend>: Sendable {
    /// Indicates the session was started.
    case start

    /// Indicates a non-recoverable error has occured, or the session was stopped, and work has halted.
    case halt(Error)

    /// Indicates the iCloud account status changed.
    case accountStatusChanged(Backend.AccountStatus)

    /// Queues up work.
    case doWork(SessionWork<Backend>)

    /// Indicates that failed work is being tried again, in the same place in the queue.
    case retryWork(SessionWork<Backend>)

    /// Indicates that work has failed.
    case workFailure(SessionWork<Backend>, Error)

    /// Indicates that work has succeeded.
    case workSuccess(SessionWork<Backend>, SessionWork<Backend>.Result)

    /// Indicates that modification work failed due to a conflict and is being sent again in the same place in the queue.
    /// Includes failed work, records to save including resolved records, and record IDs that should be deleted.
    case resolveConflict(SessionWork<Backend>, [Backend.Record], [Backend.RecordID])

    /// Indicates that work failed and should be retried after some time. Includes the wait the server suggested, if any.
    case retry(SessionWork<Backend>, Error, TimeInterval?)

    /// Indicates that the server rejected work as too large and it is being split up.
    case split(SessionWork<Backend>, Error)

    var logDescription: String {
        switch self {
        case .start:
            return "Start"
        case .halt:
            return "Halt"
        case let .accountStatusChanged(status):
            return "Account status changed: \(Backend.describe(status))"
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
        }
    }
}
