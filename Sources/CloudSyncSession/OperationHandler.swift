import CloudKit

public struct FetchOperation {
    public struct Response {
        let changeToken: CKServerChangeToken?
        let changedRecords: [CKRecord]
        let deletedRecordIDs: [CKRecord.ID]
    }

    var changeToken: CKServerChangeToken?

    init(changeToken: CKServerChangeToken?) {
        self.changeToken = changeToken
    }
}

public struct ModifyOperation {
    public struct Response {
        let savedRecords: [CKRecord]
        let deletedRecordIDs: [CKRecord.ID]
    }

    var records: [CKRecord]

    init(records: [CKRecord]) {
        self.records = records
    }
}

public struct CreateZoneOperation {
    var zoneIdentifier: CKRecordZone.ID

    init(zoneIdentifier: CKRecordZone.ID) {
        self.zoneIdentifier = zoneIdentifier
    }
}

public protocol OperationHandler {
    func handle(fetchOperation: FetchOperation, completion: @escaping (Result<FetchOperation.Response, Error>) -> Void)
    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void)
    func handle(createZoneOperation: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void)
}
