import CloudKit

public enum SyncEvent {
    case start
    case halt

    case accountStatusChanged(CKAccountStatus)

    case doWork(SyncWork)
    case retryWork(SyncWork)
    case workFailure(Error, SyncWork)
    case workSuccess(SyncWork.Result, SyncWork)

    case handleConflict
    case resolveConflict(SyncWork, [CKRecord], [CKRecord.ID])

    case retry(Error, SyncWork, TimeInterval?)
    case splitThenRetry(Error, SyncWork)

    var logDescription: String {
        switch self {
        case .start:
            return "start"
        case .halt:
            return "halt"
        case .accountStatusChanged(let status):
            return "account status changed: \(status)"
        case .doWork:
            return "do work"
        case .retryWork:
            return "retry work"
        case .workFailure:
            return "work failure"
        case .workSuccess:
            return "work success"
        case .retry:
            return "retry"
        case .splitThenRetry:
            return "split then retry"
        case .handleConflict:
            return "conflict"
        case .resolveConflict(_, let records, let recordIDsToDelete):
            return "resolved \(records.count) records with \(recordIDsToDelete.count) deleted"
        }
    }
}
