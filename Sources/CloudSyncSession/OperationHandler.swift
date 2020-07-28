import CloudKit

struct ModifyOperation {
    var records: [CKRecord]

    init(records: [CKRecord]) {
        self.records = records
    }
}

protocol OperationHandler {
    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<[CKRecord], Error>) -> Void)
}
