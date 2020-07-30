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
        dispatch: @escaping (SyncEvent) -> Void
    ) {
        os_log("%{public}@", log: log, type: .debug, #function)

        let recordsToSave = modifyOperation.records
        let recordIDsToDelete = [CKRecord.ID]()

        guard !recordIDsToDelete.isEmpty || !recordsToSave.isEmpty else {
            dispatch(.modifyCompleted([], []))

            return
        }

        let operation = CKModifyRecordsOperation(
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete
        )

        operation.modifyRecordsCompletionBlock = { serverRecords, deletedRecordIDs, error in
            if let error = error {
                dispatch(.modifyFailure(error, modifyOperation))
            } else {
                dispatch(.modifyCompleted(serverRecords ?? [], deletedRecordIDs ?? []))
            }
        }

        operation.savePolicy = savePolicy
        operation.qualityOfService = qos
        operation.database = database

        operationQueue.addOperation(operation)
    }

    public func handle(fetchOperation: FetchOperation, dispatch: @escaping (SyncEvent) -> Void) {
        os_log("%{public}@", log: log, type: .debug, #function)

        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []

        let operation = CKFetchRecordZoneChangesOperation()

        let token: CKServerChangeToken? = fetchOperation.changeToken

        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: token,
            resultsLimit: nil,
            desiredKeys: nil
        )

        operation.configurationsByRecordZoneID = [zoneIdentifier: config]

        operation.recordZoneIDs = [zoneIdentifier]
        operation.fetchAllChanges = true

        // Called if the record zone fetch was not fully completed
        operation.recordZoneChangeTokensUpdatedBlock = { [weak self] _, changeToken, _ in
            guard let self = self else { return }

            guard let changeToken = changeToken else { return }

            // The fetch may have failed halfway through, so we need to save the change token,
            // emit the current records, and then clear the arrays so we can re-request for the
            // rest of the data.
            os_log("Commiting new change token and dispatching changes", log: self.log, type: .debug)
            dispatch(.fetchCompleted(changedRecords, deletedRecordIDs))
            dispatch(.setChangeToken(changeToken))
            changedRecords = []
            deletedRecordIDs = []
        }

        // Called after the record zone fetch completes
        operation.recordZoneFetchCompletionBlock = { [weak self] _, token, _, _, error in
            guard let self = self else { return }

            if let error = error as? CKError {
                os_log(
                    "Failed to fetch record zone changes: %{public}@",
                    log: self.log,
                    type: .error,
                    String(describing: error)
                )

                if error.code == .changeTokenExpired {
                    os_log(
                        "Change token expired, resetting token and trying again",
                        log: self.log,
                        type: .error
                    )

                    dispatch(.clearChangeToken)
                } else {
                    dispatch(.fetchFailure(error, fetchOperation))
                }
            } else {
                if let token = token {
                    os_log("Commiting new change token", log: self.log, type: .debug)

                    dispatch(.setChangeToken(token))
                } else {
                    os_log("Confusingly received nil token", log: self.log, type: .debug)
                }
            }
        }

        operation.recordChangedBlock = { record in
            changedRecords.append(record)
        }

        operation.recordWithIDWasDeletedBlock = { recordID, recordType in
            deletedRecordIDs.append(recordID)
        }

        operation.fetchRecordZoneChangesCompletionBlock = { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                os_log(
                    "Failed to fetch record zone changes: %{public}@",
                    log: self.log,
                    type: .error,
                    String(describing: error)
                )

                dispatch(.fetchFailure(error, fetchOperation))
            } else {
                os_log("Finished fetching record zone changes", log: self.log, type: .info)

                dispatch(.fetchCompleted(changedRecords, deletedRecordIDs))
                changedRecords = []
                deletedRecordIDs = []
            }
        }

        operation.qualityOfService = qos
        operation.database = database

        operationQueue.addOperation(operation)
    }

    public func handle(createZoneOperation: CreateZoneOperation, dispatch: @escaping (SyncEvent) -> Void) {
        self.checkCustomZone(zoneIdentifier: createZoneOperation.zoneIdentifier) { result in
            switch result {
            case let .failure(error):
                dispatch(.createZoneFailure(error, createZoneOperation))
            case let .success(hasCreatedZone):
                if hasCreatedZone {
                    dispatch(.zoneStatusChanged(true))
                } else {
                    // CREATE ZONE
                }
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
