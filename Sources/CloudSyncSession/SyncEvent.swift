import CloudKit

public enum SyncEvent {
    case start
    case accountStatusChanged(CKAccountStatus)
    case modify([CKRecord])
    case resolveConflict([CKRecord])
    case `continue`
    case halt
    case backoff
    case createZone
    case retry
    case splitThenRetry
    case conflict
    case partialFailure

    var logDescription: String {
        switch self {
        case .start:
            return "start"
        case .accountStatusChanged(let status):
            return "account status changed: \(status)"
        case .modify(let records):
            return "modify \(records.count) records"
        case .resolveConflict(let records):
            return "resolved \(records.count) records"
        case .continue:
            return "continue"
        case .halt:
            return "halt"
        case .backoff:
            return "backoff"
        case .createZone:
            return "create zone"
        case .retry:
            return "retry"
        case .splitThenRetry:
            return "split then retry"
        case .conflict:
            return "conflict"
        case .partialFailure:
            return "partial failure"
        }
    }
}
