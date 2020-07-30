import CloudKit

public enum SyncEvent {
    case start
    case accountStatusChanged(CKAccountStatus)
    case zoneStatusChanged(Bool)
    case fetch(CKServerChangeToken?)
    case fetchFailure(Error, FetchOperation)
    case fetchCompleted(FetchOperation.Response)
    case clearChangeToken
    case modify([CKRecord])
    case modifyFailure(Error, ModifyOperation)
    case modifyCompleted(ModifyOperation.Response)
    case createZoneFailure(Error, CreateZoneOperation)
    case createZoneCompleted
    case resolveConflict([CKRecord])
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
        case .zoneStatusChanged(let isZoneCreated):
            return "zone status changed: \(isZoneCreated)"
        case .fetch:
            return "fetch"
        case .fetchFailure:
            return "fetch failure"
        case let .fetchCompleted(operationResponse):
            return "fetch completed with \(operationResponse.changedRecords.count) saved and \(operationResponse.deletedRecordIDs.count) deleted records"
        case .clearChangeToken:
            return "clear change token"
        case .modify(let records):
            return "modify \(records.count) records"
        case .modifyFailure:
            return "modify failure"
        case let .modifyCompleted(operationResponse):
            return "saved \(operationResponse.savedRecords.count) and deleted \(operationResponse.deletedRecordIDs.count) records"
        case .createZoneFailure:
            return "create zone failure"
        case .createZoneCompleted:
            return "create zone completed"
        case .resolveConflict(let records):
            return "resolved \(records.count) records"
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
