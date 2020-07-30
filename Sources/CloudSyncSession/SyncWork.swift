import CloudKit

public enum SyncWork: Equatable {
    case modify(ModifyOperation)
    case fetch(FetchOperation)
    case createZone(CreateZoneOperation)

    var retryCount: Int {
        switch self {
        case .modify(let operation):
            return operation.retryCount
        case .fetch(let operation):
            return operation.retryCount
        case .createZone(let operation):
            return operation.retryCount
        }
    }
}

protocol SyncOperation {
    var retryCount: Int { get set }
}

public struct FetchOperation: Equatable {
    public struct Response {
        let changeToken: CKServerChangeToken?
        let changedRecords: [CKRecord]
        let deletedRecordIDs: [CKRecord.ID]
        let hasMore: Bool
    }

    var changeToken: CKServerChangeToken?
    var retryCount: Int = 0

    init(changeToken: CKServerChangeToken?) {
        self.changeToken = changeToken
    }
}

public struct ModifyOperation: Equatable, SyncOperation {
    public struct Response {
        let savedRecords: [CKRecord]
        let deletedRecordIDs: [CKRecord.ID]
    }

    var records: [CKRecord]
    var recordIDsToDelete: [CKRecord.ID]
    var retryCount: Int = 0

    init(records: [CKRecord], recordIDsToDelete: [CKRecord.ID]) {
        self.records = records
        self.recordIDsToDelete = recordIDsToDelete
    }
}

public struct CreateZoneOperation: Equatable {
    var zoneIdentifier: CKRecordZone.ID
    var retryCount: Int = 0

    init(zoneIdentifier: CKRecordZone.ID) {
        self.zoneIdentifier = zoneIdentifier
    }
}
