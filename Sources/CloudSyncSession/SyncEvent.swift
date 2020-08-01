import CloudKit

public enum SyncEvent {
    case start
    case halt

    case accountStatusChanged(CKAccountStatus)

    case doWork(SyncWork)
    case retryWork(SyncWork)
    case workFailure(SyncWork, Error)
    case workSuccess(SyncWork, SyncWork.Result)

    case handleConflict
    case resolveConflict(SyncWork, [CKRecord], [CKRecord.ID])

    case retry(SyncWork, Error, TimeInterval?)
    case split(SyncWork, Error)

    case noop

    var logDescription: String {
        switch self {
        case .start:
            return "Start"
        case .halt:
            return "Halt"
        case .accountStatusChanged(let status):
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
        case .handleConflict:
            return "Conflict"
        case .resolveConflict(_, let records, let recordIDsToDelete):
            return "Resolved \(records.count) records with \(recordIDsToDelete.count) deleted"
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
        @unknown default:
            return "Unknown"
        }
    }
}
