//
// Copyright (c) 2020 Jay Hickey
// Copyright (c) 2020-present Ryan Ashcraft
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

import CloudKit
import PID

/// An object that handles all of the key operations (fetch, modify, create zone, and create subscription) using the standard CloudKit APIs.
public class CloudKitOperationHandler: OperationHandler {
    static let minThrottleDuration: TimeInterval = 1
    static let maxThrottleDuration: TimeInterval = 60 * 10

    let database: CKDatabase
    let zoneID: CKRecordZone.ID
    let subscriptionID: String
    let savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .ifServerRecordUnchanged
    let qos: QualityOfService = .userInitiated
    var rateLimitController = RateLimitPIDController(
        kp: 2,
        ki: 0.05,
        kd: 0.02,
        errorWindowSize: 20,
        targetSuccessRate: 0.96,
        initialRateLimit: 2,
        outcomeWindowSize: 1
    )

    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    var throttleDuration: TimeInterval {
        didSet {
            nextOperationDeadline = DispatchTime.now() + throttleDuration

            if throttleDuration > oldValue {
                Log.operations.info("Increasing throttle duration from \(Int(oldValue)) seconds to \(Int(throttleDuration)) seconds")
            } else if throttleDuration < oldValue {
                Log.operations.info("Decreasing throttle duration from \(Int(oldValue)) seconds to \(Int(throttleDuration)) seconds")
            }
        }
    }

    var nextOperationDeadline: DispatchTime?

    public init(database: CKDatabase, zoneID: CKRecordZone.ID, subscriptionID: String) {
        self.database = database
        self.zoneID = zoneID
        self.subscriptionID = subscriptionID
        throttleDuration = rateLimitController.rateLimit
    }

    private func queueOperation(_ operation: Operation) {
        let deadline: DispatchTime = nextOperationDeadline ?? DispatchTime.now()

        DispatchQueue.main.asyncAfter(deadline: deadline) {
            self.operationQueue.addOperation(operation)
        }
    }

    private func onOperationSuccess() {
        rateLimitController.record(outcome: .success)
        throttleDuration = min(Self.maxThrottleDuration, max(Self.minThrottleDuration, rateLimitController.rateLimit))
    }

    private func onOperationError(_ error: Error) {
        if let ckError = error as? CKError {
            rateLimitController.record(outcome: ckError.indicatesShouldBackoff ? .failure : .success)

            if let suggestedBackoffSeconds = ckError.suggestedBackoffSeconds {
                Log.operations.info("CloudKit error suggests retrying after \(suggestedBackoffSeconds) seconds")

                // Respect the amount suggested for the next operation
                throttleDuration = suggestedBackoffSeconds
            } else {
                throttleDuration = min(Self.maxThrottleDuration, max(Self.minThrottleDuration, rateLimitController.rateLimit))
            }
        }
    }

    public func handle(
        modifyOperation: ModifyOperation,
        completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void
    ) {
        let recordsToSave = modifyOperation.records
        let recordIDsToDelete = modifyOperation.recordIDsToDelete

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
                Log.operations.error("Failed to modify records: \(error)")
                self.onOperationError(error)

                completion(.failure(error))
            } else {
                self.onOperationSuccess()

                completion(.success(ModifyOperation.Response(savedRecords: serverRecords ?? [], deletedRecordIDs: deletedRecordIDs ?? [])))
            }
        }

        operation.savePolicy = savePolicy
        operation.qualityOfService = qos
        operation.database = database

        queueOperation(operation)
    }

    public func handle(fetchOperation: FetchOperation, completion: @escaping (Result<FetchOperation.Response, Error>) -> Void) {
        var hasMore = false
        var token: CKServerChangeToken? = fetchOperation.changeToken
        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []

        let operation = CKFetchRecordZoneChangesOperation()

        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: token,
            resultsLimit: nil,
            desiredKeys: nil
        )

        operation.configurationsByRecordZoneID = [zoneID: config]

        operation.recordZoneIDs = [zoneID]
        operation.fetchAllChanges = true

        operation.recordZoneChangeTokensUpdatedBlock = { [weak self] _, newToken, _ in
            guard let self = self else {
                return
            }

            guard let newToken = newToken else {
                return
            }

            Log.operations.debug("Received new change token")

            token = newToken
        }

        operation.recordChangedBlock = { record in
            changedRecords.append(record)
        }

        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            deletedRecordIDs.append(recordID)
        }

        operation.recordZoneFetchCompletionBlock = { [weak self] _, newToken, _, newHasMore, _ in
            guard let self = self else {
                return
            }

            hasMore = newHasMore

            if let newToken = newToken {
                Log.operations.debug("Received new change token")

                token = newToken
            } else {
                Log.operations.debug("Confusingly received nil token")

                token = nil
            }
        }

        operation.fetchRecordZoneChangesCompletionBlock = { [weak self] error in
            guard let self = self else {
                return
            }

            if let error = error {
                Log.operations.error("Failed to fetch record zone changes: \(error)")

                onOperationError(error)

                completion(.failure(error))
            } else {
                Log.operations.info("Finished fetching record zone changes")

                onOperationSuccess()

                completion(
                    .success(
                        FetchOperation.Response(
                            changeToken: token,
                            changedRecords: changedRecords,
                            deletedRecordIDs: deletedRecordIDs,
                            hasMore: hasMore
                        )
                    )
                )
            }
        }

        operation.qualityOfService = qos
        operation.database = database

        queueOperation(operation)
    }

    public func handle(createZoneOperation: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void) {
        checkCustomZone(zoneID: createZoneOperation.zoneID) { result in
            switch result {
            case let .failure(error):
                if let ckError = error as? CKError {
                    switch ckError.code {
                    case .partialFailure,
                         .zoneNotFound,
                         .userDeletedZone:
                        self.createCustomZone(zoneID: self.zoneID) { result in
                            switch result {
                            case let .failure(error):
                                completion(.failure(error))
                            case let .success(didCreateZone):
                                completion(.success(didCreateZone))
                            }
                        }

                        return
                    default:
                        break
                    }
                }

                completion(.failure(error))
            case let .success(isZoneAlreadyCreated):
                if isZoneAlreadyCreated {
                    completion(.success(true))

                    return
                }

                self.createCustomZone(zoneID: self.zoneID) { result in
                    switch result {
                    case let .failure(error):
                        completion(.failure(error))
                    case let .success(didCreateZone):
                        completion(.success(didCreateZone))
                    }
                }
            }
        }
    }

    public func handle(createSubscriptionOperation _: CreateSubscriptionOperation, completion: @escaping (Result<Bool, Error>) -> Void) {
        checkSubscription(zoneID: zoneID) { result in
            switch result {
            case let .failure(error):
                if let ckError = error as? CKError {
                    switch ckError.code {
                    case .partialFailure,
                         .zoneNotFound,
                         .userDeletedZone:
                        self.createSubscription(zoneID: self.zoneID, subscriptionID: self.subscriptionID) { result in
                            switch result {
                            case let .failure(error):
                                completion(.failure(error))
                            case let .success(didCreateSubscription):
                                completion(.success(didCreateSubscription))
                            }
                        }

                        return
                    default:
                        break
                    }
                }

                completion(.failure(error))
            case let .success(isSubscriptionAlreadyCreated):
                if isSubscriptionAlreadyCreated {
                    completion(.success(true))

                    return
                }

                self.createSubscription(zoneID: self.zoneID, subscriptionID: self.subscriptionID) { result in
                    switch result {
                    case let .failure(error):
                        completion(.failure(error))
                    case let .success(didCreateZone):
                        completion(.success(didCreateZone))
                    }
                }
            }
        }
    }
}

private extension CloudKitOperationHandler {
    func checkCustomZone(zoneID: CKRecordZone.ID, completion: @escaping (Result<Bool, Error>) -> Void) {
        let operation = CKFetchRecordZonesOperation(recordZoneIDs: [zoneID])

        operation.fetchRecordZonesCompletionBlock = { ids, error in
            if let error = error {
                Log.operations.error("Failed to check for custom zone existence: \(String(describing: error))")

                completion(.failure(error))

                return
            } else if (ids ?? [:]).isEmpty {
                Log.operations.error("Custom zone reported as existing, but it doesn't exist")

                completion(.success(false))

                return
            }

            Log.operations.debug("Custom zone exists")

            completion(.success(true))
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        queueOperation(operation)
    }

    func createCustomZone(zoneID: CKRecordZone.ID, completion: @escaping (Result<Bool, Error>) -> Void) {
        let zone = CKRecordZone(zoneID: zoneID)
        let operation = CKModifyRecordZonesOperation(
            recordZonesToSave: [zone],
            recordZoneIDsToDelete: nil
        )

        operation.modifyRecordZonesCompletionBlock = { _, _, error in
            if let error = error {
                Log.operations.error("Failed to create custom zone: \(String(describing: error))")

                completion(.failure(error))

                return
            }

            Log.operations.debug("Created custom zone")

            completion(.success(true))
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        queueOperation(operation)
    }

    func checkSubscription(zoneID _: CKRecordZone.ID, completion: @escaping (Result<Bool, Error>) -> Void) {
        let operation = CKFetchSubscriptionsOperation(subscriptionIDs: [subscriptionID])

        operation.fetchSubscriptionCompletionBlock = { ids, error in
            if let error = error {
                Log.operations.error("Failed to check for subscription existence: \(String(describing: error))")

                completion(.failure(error))

                return
            } else if (ids ?? [:]).isEmpty {
                Log.operations.error("Subscription reported as existing, but it doesn't exist")

                completion(.success(false))

                return
            }

            Log.operations.debug("Subscription exists")

            completion(.success(true))
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        queueOperation(operation)
    }

    func createSubscription(zoneID: CKRecordZone.ID, subscriptionID: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        let subscription = CKRecordZoneSubscription(
            zoneID: zoneID,
            subscriptionID: subscriptionID
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true

        subscription.notificationInfo = notificationInfo

        let operation = CKModifySubscriptionsOperation(
            subscriptionsToSave: [subscription],
            subscriptionIDsToDelete: nil
        )

        operation.modifySubscriptionsCompletionBlock = { _, _, error in
            if let error = error {
                Log.operations.error("Failed to create subscription: \(String(describing: error))")

                completion(.failure(error))

                return
            }

            Log.operations.debug("Created subscription")

            completion(.success(true))
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        queueOperation(operation)
    }
}
