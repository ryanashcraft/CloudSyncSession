import CloudKit

public enum SyncEvent {
    case start
    case accountStatusChanged(CKAccountStatus)
    case zoneStatusChanged(Bool)
    case workFailure(Error, SyncWork)
    case fetch(CKServerChangeToken?)
    case fetchCompleted(FetchOperation.Response)
    case clearChangeToken
    case modify([CKRecord], [CKRecord.ID])
    case modifyCompleted(ModifyOperation.Response)
    case createZoneCompleted
    case resolveConflict([CKRecord], [CKRecord.ID])
    case halt
    case createZone
    case retry(Error, SyncWork)
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
        case .workFailure:
            return "fetch failure"
        case let .fetchCompleted(operationResponse):
            return "fetch completed with \(operationResponse.changedRecords.count) saved and \(operationResponse.deletedRecordIDs.count) deleted records"
        case .clearChangeToken:
            return "clear change token"
        case .modify(let records, let recordIDsToDelete):
            return "modify \(records.count) and delete \(recordIDsToDelete.count) records"
        case let .modifyCompleted(operationResponse):
            return "saved \(operationResponse.savedRecords.count) and deleted \(operationResponse.deletedRecordIDs.count) records"
        case .createZoneCompleted:
            return "create zone completed"
        case .resolveConflict(let records, let recordIDsToDelete):
            return "resolved \(records.count) records with \(recordIDsToDelete.count) deleted"
        case .halt:
            return "halt"
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
