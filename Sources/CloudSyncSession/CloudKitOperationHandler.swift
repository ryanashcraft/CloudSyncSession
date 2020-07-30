import CloudKit
import os.log

public class CloudKitOperationHandler: OperationHandler {
    let database: CKDatabase
    let zoneIdentifier: CKRecordZone.ID
    let operationQueue: OperationQueue
    let log: OSLog
    let savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .ifServerRecordUnchanged
    let qos: QualityOfService = .userInitiated

    public init(database: CKDatabase, zoneIdentifier: CKRecordZone.ID, operationQueue: OperationQueue, log: OSLog) {
        self.database = database
        self.zoneIdentifier = zoneIdentifier
        self.operationQueue = operationQueue
        self.log = log
    }

    public func handle(
        modifyOperation: ModifyOperation,
        completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void
    ) {
        os_log("%{public}@", log: log, type: .debug, #function)

        let recordsToSave = modifyOperation.records
        let recordIDsToDelete = [CKRecord.ID]()

        guard !recordIDsToDelete.isEmpty || !recordsToSave.isEmpty else {
            completion(.success(ModifyOperation.Response(savedRecords: [], deletedRecordIDs: [])))

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
                completion(.success(ModifyOperation.Response(savedRecords: serverRecords ?? [], deletedRecordIDs: deletedRecordIDs ?? [])))
            }
        }

        operation.savePolicy = savePolicy
        operation.qualityOfService = qos
        operation.database = database

        operationQueue.addOperation(operation)
    }

    public func handle(fetchOperation: FetchOperation, completion: @escaping (Result<FetchOperation.Response, Error>) -> Void) {
        os_log("%{public}@", log: log, type: .debug, #function)

        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []

        let operation = CKFetchRecordZoneChangesOperation()

        var token: CKServerChangeToken? = fetchOperation.changeToken

        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: token,
            resultsLimit: nil,
            desiredKeys: nil
        )

        operation.configurationsByRecordZoneID = [zoneIdentifier: config]

        operation.recordZoneIDs = [zoneIdentifier]
        operation.fetchAllChanges = true

        operation.recordZoneChangeTokensUpdatedBlock = { [weak self] _, newToken, _ in
            guard let self = self else {
                return
            }

            guard let newToken = newToken else {
                return
            }

            os_log("Received new change token", log: self.log, type: .debug)

            token = newToken
        }

        operation.recordChangedBlock = { record in
            changedRecords.append(record)
        }

        operation.recordWithIDWasDeletedBlock = { recordID, recordType in
            deletedRecordIDs.append(recordID)
        }

        operation.recordZoneFetchCompletionBlock = { [weak self] _, newToken, _, _, _ in
            guard let self = self else {
                return
            }

            if let newToken = newToken {
                os_log("Received new change token", log: self.log, type: .debug)

                token = newToken
            } else {
                os_log("Confusingly received nil token", log: self.log, type: .debug)

                token = nil
            }
        }

        operation.fetchRecordZoneChangesCompletionBlock = { [weak self] error in
            guard let self = self else {
                return
            }

            if let error = error {
                os_log(
                    "Failed to fetch record zone changes: %{public}@",
                    log: self.log,
                    type: .error,
                    String(describing: error)
                )

                completion(.failure(error))
            } else {
                os_log("Finished fetching record zone changes", log: self.log, type: .info)

                completion(.success(FetchOperation.Response(changeToken: token, changedRecords: changedRecords, deletedRecordIDs: deletedRecordIDs)))
            }
        }

        operation.qualityOfService = qos
        operation.database = database

        operationQueue.addOperation(operation)
    }

    public func handle(createZoneOperation: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void) {
        self.checkCustomZone(zoneIdentifier: createZoneOperation.zoneIdentifier) { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(hasCreatedZone):
                completion(.success(hasCreatedZone))
            }
        }
    }

    private func checkCustomZone(zoneIdentifier: CKRecordZone.ID, completion: @escaping (Result<Bool, Error>) -> Void) {
        let operation = CKFetchRecordZonesOperation(recordZoneIDs: [zoneIdentifier])

        operation.fetchRecordZonesCompletionBlock = { ids, error in
            if let error = error {
                os_log(
                    "Failed to check for custom zone existence: %{public}@",
                    log: self.log,
                    type: .error,
                    String(describing: error)
                )

                completion(.failure(error))
            } else if (ids ?? [:]).isEmpty {
                os_log(
                    "Custom zone reported as existing, but it doesn't exist",
                    log: self.log,
                    type: .error
                )

                completion(.success(false))
            } else {
                os_log(
                    "Custom zone exists",
                    log: self.log,
                    type: .error
                )

                completion(.success(true))
            }
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        operationQueue.addOperation(operation)
    }
}
