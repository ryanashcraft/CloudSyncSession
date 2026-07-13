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
    static let minThrottleDuration: TimeInterval = 0.25
    static let maxThrottleDuration: TimeInterval = 60 * 10

    let database: CKDatabase
    let zoneID: CKRecordZone.ID
    let subscriptionID: String
    let savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .ifServerRecordUnchanged
    let qos: QualityOfService = .userInitiated
    /// Guards rateLimitController, throttleDuration, and nextOperationDeadline,
    /// which are mutated from CloudKit callback threads and read when queueing.
    private let throttleLock = NSLock()

    private var rateLimitController = RateLimitPIDController(
        kp: 2,
        ki: 0.05,
        kd: 0.02,
        errorWindowSize: 20,
        targetSuccessRate: 0.96,
        initialRateLimit: 1,
        outcomeWindowSize: 1
    )

    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    private var throttleDuration: TimeInterval {
        didSet {
            nextOperationDeadline = DispatchTime.now() + throttleDuration

            if throttleDuration > oldValue {
                Log.operations.info("Increasing throttle duration from \(String(format: "%.2f", oldValue))s to \(String(format: "%.2f", throttleDuration))s")
            } else if throttleDuration < oldValue {
                Log.operations.info("Decreasing throttle duration from \(String(format: "%.2f", oldValue))s to \(String(format: "%.2f", throttleDuration))s")
            }
        }
    }

    private var nextOperationDeadline: DispatchTime?

    public init(database: CKDatabase, zoneID: CKRecordZone.ID, subscriptionID: String) {
        self.database = database
        self.zoneID = zoneID
        self.subscriptionID = subscriptionID
        throttleDuration = rateLimitController.rateLimit
    }

    private func queueOperation(_ operation: Operation) {
        throttleLock.lock()
        let deadline: DispatchTime = nextOperationDeadline ?? DispatchTime.now()
        throttleLock.unlock()

        DispatchQueue.main.asyncAfter(deadline: deadline) {
            self.operationQueue.addOperation(operation)
        }
    }

    private func onOperationSuccess() {
        throttleLock.lock()
        defer { throttleLock.unlock() }

        rateLimitController.record(outcome: .success)
        throttleDuration = min(Self.maxThrottleDuration, max(Self.minThrottleDuration, rateLimitController.rateLimit))
    }

    private func onOperationError(_ error: Error) {
        guard let ckError = error as? CKError else {
            return
        }

        throttleLock.lock()
        defer { throttleLock.unlock() }

        rateLimitController.record(outcome: ckError.indicatesShouldBackoff ? .failure : .success)

        if let suggestedBackoffSeconds = ckError.suggestedBackoffSeconds {
            Log.operations.info("CloudKit error suggests retrying after \(suggestedBackoffSeconds) seconds")

            // Respect the amount suggested for the next operation
            throttleDuration = suggestedBackoffSeconds
        } else {
            throttleDuration = min(Self.maxThrottleDuration, max(Self.minThrottleDuration, rateLimitController.rateLimit))
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

        let accumulationLock = NSLock()
        var savedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []

        operation.perRecordSaveBlock = { _, result in
            if case let .success(record) = result {
                accumulationLock.lock()
                savedRecords.append(record)
                accumulationLock.unlock()
            }
        }

        operation.perRecordDeleteBlock = { recordID, result in
            if case .success = result {
                accumulationLock.lock()
                deletedRecordIDs.append(recordID)
                accumulationLock.unlock()
            }
        }

        operation.modifyRecordsResultBlock = { result in
            switch result {
            case .success:
                self.onOperationSuccess()

                accumulationLock.lock()
                let response = ModifyOperation.Response(savedRecords: savedRecords, deletedRecordIDs: deletedRecordIDs)
                accumulationLock.unlock()

                completion(.success(response))
            case let .failure(error):
                Log.operations.error("Failed to modify records: \(error)")

                self.onOperationError(error)

                completion(.failure(error))
            }
        }

        operation.savePolicy = savePolicy
        operation.qualityOfService = qos
        operation.database = database

        queueOperation(operation)
    }

    public func handle(fetchOperation: FetchOperation, completion: @escaping (Result<FetchOperation.Response, Error>) -> Void) {
        let accumulationLock = NSLock()
        var hasMore = false
        var token: CKServerChangeToken? = fetchOperation.changeToken
        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []

        let operation = CKFetchRecordZoneChangesOperation()

        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: fetchOperation.changeToken,
            resultsLimit: maxRecommendedRecordsPerFetchOperation,
            desiredKeys: nil
        )

        operation.configurationsByRecordZoneID = [zoneID: config]

        operation.recordZoneIDs = [zoneID]
        operation.fetchAllChanges = false

        operation.recordZoneChangeTokensUpdatedBlock = { _, newToken, _ in
            guard let newToken = newToken else {
                return
            }

            Log.operations.debug("Received new change token")

            accumulationLock.lock()
            token = newToken
            accumulationLock.unlock()
        }

        operation.recordWasChangedBlock = { _, result in
            switch result {
            case let .success(record):
                accumulationLock.lock()
                changedRecords.append(record)
                accumulationLock.unlock()
            case let .failure(error):
                Log.operations.error("Failed to fetch record: \(error)")
            }
        }

        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            accumulationLock.lock()
            deletedRecordIDs.append(recordID)
            accumulationLock.unlock()
        }

        operation.recordZoneFetchResultBlock = { _, result in
            switch result {
            case let .success((newToken, _, newHasMore)):
                Log.operations.debug("Received new change token")

                accumulationLock.lock()
                hasMore = newHasMore
                token = newToken
                accumulationLock.unlock()
            case let .failure(error):
                Log.operations.error("Failed to fetch record zone: \(error)")
            }
        }

        operation.fetchRecordZoneChangesResultBlock = { result in
            switch result {
            case .success:
                Log.operations.info("Finished fetching record zone changes")

                self.onOperationSuccess()

                accumulationLock.lock()
                let response = FetchOperation.Response(
                    changeToken: token,
                    changedRecords: changedRecords,
                    deletedRecordIDs: deletedRecordIDs,
                    hasMore: hasMore
                )
                accumulationLock.unlock()

                completion(.success(response))
            case let .failure(error):
                Log.operations.error("Failed to fetch record zone changes: \(error)")

                self.onOperationError(error)

                completion(.failure(error))
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
                        self.createCustomZone(zoneID: self.zoneID, completion: completion)

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

                self.createCustomZone(zoneID: self.zoneID, completion: completion)
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
                        self.createSubscription(zoneID: self.zoneID, subscriptionID: self.subscriptionID, completion: completion)

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

                self.createSubscription(zoneID: self.zoneID, subscriptionID: self.subscriptionID, completion: completion)
            }
        }
    }
}

private extension CloudKitOperationHandler {
    func checkCustomZone(zoneID: CKRecordZone.ID, completion: @escaping (Result<Bool, Error>) -> Void) {
        let operation = CKFetchRecordZonesOperation(recordZoneIDs: [zoneID])

        operation.fetchRecordZonesResultBlock = { result in
            switch result {
            case .success:
                Log.operations.debug("Custom zone exists")

                completion(.success(true))
            case let .failure(error):
                Log.operations.error("Failed to check for custom zone existence: \(String(describing: error))")

                completion(.failure(error))
            }
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

        operation.modifyRecordZonesResultBlock = { result in
            switch result {
            case .success:
                Log.operations.debug("Created custom zone")

                completion(.success(true))
            case let .failure(error):
                Log.operations.error("Failed to create custom zone: \(String(describing: error))")

                completion(.failure(error))
            }
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        queueOperation(operation)
    }

    func checkSubscription(zoneID _: CKRecordZone.ID, completion: @escaping (Result<Bool, Error>) -> Void) {
        let operation = CKFetchSubscriptionsOperation(subscriptionIDs: [subscriptionID])

        operation.fetchSubscriptionsResultBlock = { result in
            switch result {
            case .success:
                Log.operations.debug("Subscription exists")

                completion(.success(true))
            case let .failure(error):
                Log.operations.error("Failed to check for subscription existence: \(String(describing: error))")

                completion(.failure(error))
            }
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

        operation.modifySubscriptionsResultBlock = { result in
            switch result {
            case .success:
                Log.operations.debug("Created subscription")

                completion(.success(true))
            case let .failure(error):
                Log.operations.error("Failed to create subscription: \(String(describing: error))")

                completion(.failure(error))
            }
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        queueOperation(operation)
    }
}
