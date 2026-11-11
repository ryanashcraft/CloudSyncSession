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
import SyncSessionCore

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
    /// which are mutated from CloudKit callback threads and read when sending.
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

    /// Sends one CloudKit operation, once the throttle allows, and waits for the result its
    /// completion handler reports.
    ///
    /// `makeOperation` builds the operation and wires the completion handler it is given into the
    /// operation's own callbacks.
    ///
    /// If the task is cancelled while the operation is still waiting out the throttle, the
    /// operation is never sent and this throws at once.
    ///
    /// If it is cancelled after the operation has been handed to CloudKit, the operation is left
    /// to finish and its real result is returned. Cancelling a `CKOperation` at that point does
    /// not recall the request: run against CloudKit, a modify cancelled 150 ms after it was sent
    /// was reported as cancelled at once while every one of its records was saved. Cancelling
    /// would only mean returning before the server was done and without knowing what it did,
    /// and callers of the session's `stopAndWait()` rely on neither being the case.
    private func send<Value>(
        _ makeOperation: (@escaping (Result<Value, Error>) -> Void) -> Operation
    ) async throws -> Value {
        try Task.checkCancellation()

        let sending = SendingOperation<Value>(queue: operationQueue)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard sending.begin(continuation) else {
                    return
                }

                let operation = makeOperation { result in
                    sending.finish(with: result)
                }

                throttleLock.lock()
                let deadline: DispatchTime = nextOperationDeadline ?? DispatchTime.now()
                throttleLock.unlock()

                DispatchQueue.main.asyncAfter(deadline: deadline) {
                    sending.enqueue(operation)
                }
            }
        } onCancel: {
            sending.cancel()
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

    public func handle(modifyOperation: ModifyOperation) async throws -> ModifyOperation.Response {
        guard !modifyOperation.recordIDsToDelete.isEmpty || !modifyOperation.records.isEmpty else {
            return ModifyOperation.Response(savedRecords: [], deletedRecordIDs: [])
        }

        return try await send { completion in
            self.makeModifyRecordsOperation(modifyOperation, completion: completion)
        }
    }

    public func handle(fetchOperation: FetchOperation) async throws -> FetchOperation.Response {
        try await send { completion in
            self.makeFetchRecordZoneChangesOperation(fetchOperation, completion: completion)
        }
    }

    public func handle(createZoneOperation: CreateZoneOperation) async throws -> Bool {
        do {
            let isZoneAlreadyCreated = try await send { completion in
                self.makeCheckCustomZoneOperation(zoneID: createZoneOperation.zoneID, completion: completion)
            }

            if isZoneAlreadyCreated {
                return true
            }
        } catch let error as CKError where Self.meansMissing(error) {
            // The zone is not there. Go on to create it.
        }

        // Stopping between the check and the creation must not go on to create the zone.
        try Task.checkCancellation()

        return try await send { completion in
            self.makeCreateCustomZoneOperation(zoneID: self.zoneID, completion: completion)
        }
    }

    public func handle(createSubscriptionOperation _: CreateSubscriptionOperation) async throws -> Bool {
        do {
            let isSubscriptionAlreadyCreated = try await send { completion in
                self.makeCheckSubscriptionOperation(completion: completion)
            }

            if isSubscriptionAlreadyCreated {
                return true
            }
        } catch let error as CKError where Self.meansMissing(error) {
            // The subscription is not there. Go on to create it.
        }

        try Task.checkCancellation()

        return try await send { completion in
            self.makeCreateSubscriptionOperation(zoneID: self.zoneID, subscriptionID: self.subscriptionID, completion: completion)
        }
    }

    /// Whether a failed check for the zone or the subscription means it does not exist, as
    /// opposed to the check itself not having worked.
    private static func meansMissing(_ error: CKError) -> Bool {
        switch error.code {
        case .partialFailure,
             .zoneNotFound,
             .userDeletedZone:
            return true
        default:
            return false
        }
    }
}

struct FetchOperationResponseBuilder {
    private var changeToken: CKServerChangeToken?
    private var changedRecords: [CKRecord] = []
    private var deletedRecordIDs: [CKRecord.ID] = []
    private var hasMore = false
    private var fetchError: Error?

    init(changeToken: CKServerChangeToken?) {
        self.changeToken = changeToken
    }

    mutating func updateChangeToken(_ changeToken: CKServerChangeToken) {
        self.changeToken = changeToken
    }

    mutating func recordChanged(_ record: CKRecord) {
        changedRecords.append(record)
    }

    mutating func recordDeleted(_ recordID: CKRecord.ID) {
        deletedRecordIDs.append(recordID)
    }

    mutating func recordZoneFetchSucceeded(changeToken: CKServerChangeToken, hasMore: Bool) {
        self.changeToken = changeToken
        self.hasMore = hasMore
    }

    mutating func recordZoneFetchFailed(_ error: Error) {
        fetchError = fetchError ?? error
    }

    mutating func recordFetchFailed(_ error: Error) {
        fetchError = fetchError ?? error
    }

    func response() -> Result<FetchOperation.Response, Error> {
        if let fetchError {
            return .failure(fetchError)
        }

        return .success(
            FetchOperation.Response(
                changeToken: changeToken,
                changedRecords: changedRecords,
                deletedRecordIDs: deletedRecordIDs,
                hasMore: hasMore
            )
        )
    }
}

// MARK: Building the CloudKit operations

private extension CloudKitOperationHandler {
    func makeModifyRecordsOperation(
        _ modifyOperation: ModifyOperation,
        completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void
    ) -> Operation {
        let recordsToSave = modifyOperation.records
        let recordIDsToDelete = modifyOperation.recordIDsToDelete

        let operation = CKModifyRecordsOperation(
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete
        )

        // Deliberately the deprecated block: modifyRecordsResultBlock reports .success even
        // when every record in the batch failed (per-record errors never roll up on the
        // iOS 15+ API — https://developer.apple.com/forums/thread/708758), which starves
        // FailureResolver of the partialFailure it needs for conflict resolution and retry.
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

        return operation
    }

    func makeFetchRecordZoneChangesOperation(
        _ fetchOperation: FetchOperation,
        completion: @escaping (Result<FetchOperation.Response, Error>) -> Void
    ) -> Operation {
        var responseBuilder = FetchOperationResponseBuilder(changeToken: fetchOperation.changeToken)

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

            responseBuilder.updateChangeToken(newToken)
        }

        operation.recordWasChangedBlock = { _, result in
            switch result {
            case let .success(record):
                responseBuilder.recordChanged(record)
            case let .failure(error):
                Log.operations.error("Failed to fetch record: \(error)")
                responseBuilder.recordFetchFailed(error)
            }
        }

        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            responseBuilder.recordDeleted(recordID)
        }

        operation.recordZoneFetchResultBlock = { _, result in
            switch result {
            case let .success((newToken, _, newHasMore)):
                Log.operations.debug("Received new change token")

                responseBuilder.recordZoneFetchSucceeded(changeToken: newToken, hasMore: newHasMore)
            case let .failure(error):
                Log.operations.error("Failed to fetch record zone: \(error)")
                responseBuilder.recordZoneFetchFailed(error)
            }
        }

        operation.fetchRecordZoneChangesResultBlock = { result in
            switch result {
            case .success:
                switch responseBuilder.response() {
                case let .success(response):
                    Log.operations.info("Finished fetching record zone changes")

                    self.onOperationSuccess()

                    completion(.success(response))
                case let .failure(error):
                    Log.operations.error("Failed to fetch record zone changes: \(error)")

                    self.onOperationError(error)

                    completion(.failure(error))
                }
            case let .failure(error):
                Log.operations.error("Failed to fetch record zone changes: \(error)")

                self.onOperationError(error)

                completion(.failure(error))
            }
        }

        operation.qualityOfService = qos
        operation.database = database

        return operation
    }

    func makeCheckCustomZoneOperation(zoneID: CKRecordZone.ID, completion: @escaping (Result<Bool, Error>) -> Void) -> Operation {
        let operation = CKFetchRecordZonesOperation(recordZoneIDs: [zoneID])

        var foundZone = false
        var zoneFetchError: Error?

        operation.perRecordZoneResultBlock = { _, result in
            switch result {
            case .success:
                foundZone = true
            case let .failure(error):
                zoneFetchError = error
            }
        }

        operation.fetchRecordZonesResultBlock = { result in
            switch result {
            case .success:
                if let zoneFetchError {
                    Log.operations.error("Failed to check for custom zone existence: \(String(describing: zoneFetchError))")

                    completion(.failure(zoneFetchError))
                } else if foundZone {
                    Log.operations.debug("Custom zone exists")

                    completion(.success(true))
                } else {
                    Log.operations.error("Custom zone reported as existing, but it doesn't exist")

                    completion(.success(false))
                }
            case let .failure(error):
                Log.operations.error("Failed to check for custom zone existence: \(String(describing: error))")

                completion(.failure(error))
            }
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        return operation
    }

    func makeCreateCustomZoneOperation(zoneID: CKRecordZone.ID, completion: @escaping (Result<Bool, Error>) -> Void) -> Operation {
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

        return operation
    }

    func makeCheckSubscriptionOperation(completion: @escaping (Result<Bool, Error>) -> Void) -> Operation {
        let operation = CKFetchSubscriptionsOperation(subscriptionIDs: [subscriptionID])

        var foundSubscription = false
        var subscriptionFetchError: Error?

        operation.perSubscriptionResultBlock = { _, result in
            switch result {
            case .success:
                foundSubscription = true
            case let .failure(error):
                subscriptionFetchError = error
            }
        }

        operation.fetchSubscriptionsResultBlock = { result in
            switch result {
            case .success:
                switch SubscriptionExistenceResult(subscriptionFetchError: subscriptionFetchError, foundSubscription: foundSubscription).result {
                case let .failure(error):
                    Log.operations.error("Failed to check for subscription existence: \(String(describing: error))")

                    completion(.failure(error))
                case let .success(subscriptionExists):
                    if subscriptionExists {
                        Log.operations.debug("Subscription exists")

                        completion(.success(true))
                    } else {
                        Log.operations.debug("Subscription does not exist")

                        completion(.success(false))
                    }
                }
            case let .failure(error):
                Log.operations.error("Failed to check for subscription existence: \(String(describing: error))")

                completion(.failure(error))
            }
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        return operation
    }

    func makeCreateSubscriptionOperation(zoneID: CKRecordZone.ID, subscriptionID: String, completion: @escaping (Result<Bool, Error>) -> Void) -> Operation {
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

        return operation
    }
}

struct SubscriptionExistenceResult {
    let subscriptionFetchError: Error?
    let foundSubscription: Bool

    var result: Result<Bool, Error> {
        if let subscriptionFetchError {
            if let ckError = subscriptionFetchError as? CKError, ckError.code == .unknownItem {
                return .success(false)
            }

            return .failure(subscriptionFetchError)
        }

        return .success(foundSubscription)
    }
}

/// One CloudKit operation on its way through the throttle and the operation queue, and the
/// continuation waiting for its result.
///
/// It makes sure the continuation is resumed exactly once: with CloudKit's result, or with a
/// cancellation that arrived before the operation was sent.
private final class SendingOperation<Value>: @unchecked Sendable {
    private let queue: OperationQueue
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: Operation?
    private var isCancelled = false

    init(queue: OperationQueue) {
        self.queue = queue
    }

    /// Takes the continuation to resume. Returns false, having resumed it, if cancellation got
    /// here first.
    func begin(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()

        if isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())

            return false
        }

        self.continuation = continuation
        lock.unlock()

        return true
    }

    /// Hands the operation to the queue once the throttle has let it through, unless it was
    /// cancelled while waiting.
    func enqueue(_ operation: Operation) {
        lock.lock()
        defer { lock.unlock() }

        guard !isCancelled else {
            return
        }

        // Recorded under the same lock as the check in `cancel()`, so a cancellation finds the
        // operation either not sent, and stops it here, or sent, and leaves it alone.
        self.operation = operation
        queue.addOperation(operation)
    }

    func finish(with result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let isWithCloudKit = operation != nil
        lock.unlock()

        // Sent already: left to finish, and its completion handler resumes the continuation.
        // Still waiting out the throttle: it will never be sent, so there is nothing to wait for.
        if !isWithCloudKit {
            finish(with: .failure(CancellationError()))
        }
    }
}
