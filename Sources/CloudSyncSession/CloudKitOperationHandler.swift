import CloudKit

public class CloudKitOperationHandler: OperationHandler {
    let database: CKDatabase
    let operationQueue: OperationQueue
    let savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .ifServerRecordUnchanged
    let qos: QualityOfService = .userInitiated

    public init(database: CKDatabase, operationQueue: OperationQueue) {
        self.database = database
        self.operationQueue = operationQueue
    }

    public func handle(
        modifyOperation: ModifyOperation,
        completion: @escaping (Result<[CKRecord], Error>) -> Void
    ) {
        let recordsToSave = modifyOperation.records
        let recordIDsToDelete = [CKRecord.ID]()

        guard !recordIDsToDelete.isEmpty || !recordsToSave.isEmpty else {
            completion(.success([]))

            return
        }

        let operation = CKModifyRecordsOperation(
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete
        )

        operation.modifyRecordsCompletionBlock = { serverRecords, deletedRecordIDs, error in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(serverRecords ?? []))
            }
        }

        operation.savePolicy = savePolicy
        operation.qualityOfService = qos
        operation.database = database

        operationQueue.addOperation(operation)
    }
}
