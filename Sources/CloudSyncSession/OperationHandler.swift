import CloudKit

public struct ModifyOperation {
    var records: [CKRecord]

    init(records: [CKRecord]) {
        self.records = records
    }
}

public protocol OperationHandler {
    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<[CKRecord], Error>) -> Void)
}
