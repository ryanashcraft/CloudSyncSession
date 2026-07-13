@testable import CloudSyncSession
import CloudKit
import XCTest

final class SessionPerformTests: XCTestCase {
    func testPerformFetchReturnsResponse() async throws {
        let session = makeStartedSession(handler: SuccessfulMockOperationHandler())

        let response = try await session.perform(FetchOperation(changeToken: nil))

        XCTAssertFalse(response.changedRecords.isEmpty)
    }

    func testPerformFetchSurvivesRetry() async throws {
        // networkUnavailable maps to a retry with no suggested interval;
        // the backoff for retryCount 0 is zero seconds, so the test is fast.
        let handler = FailOnceFetchMockOperationHandler(error: CKError(.networkUnavailable))
        let session = makeStartedSession(handler: handler)

        let response = try await session.perform(FetchOperation(changeToken: nil))

        XCTAssertFalse(response.changedRecords.isEmpty)
    }

    func testPerformModifyCorrelatesByCheckpointAcrossSplit() async throws {
        let session = makeStartedSession(handler: SuccessfulMockOperationHandler())
        let checkpointID = UUID()
        let operation = ModifyOperation(
            records: (0 ..< 900).map { _ in makeTestRecord() },
            recordIDsToDelete: [],
            checkpointID: checkpointID,
            userInfo: nil
        )

        let response = try await session.perform(operation)

        // The waiter resolves with the final chunk's response. 900 records
        // split into 400/400/100, so the final chunk saves 100 records.
        XCTAssertEqual(response.savedRecords.count, 100)
    }

    func testPerformFetchThrowsOnHaltWhileAwaiting() async {
        let session = makeStartedSession(handler: NeverCompletingMockOperationHandler())

        async let pendingResponse = session.perform(FetchOperation(changeToken: nil))

        // Give the waiter time to register before halting.
        try? await Task.sleep(nanoseconds: 100_000_000)
        session.stop()

        do {
            _ = try await pendingResponse
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is StopError)
        }
    }

    func testPerformThrowsImmediatelyWhenAlreadyHalted() async {
        let session = makeStartedSession(handler: NeverCompletingMockOperationHandler())

        session.stop()

        // Wait for the halt to reach the waiter registry on the main queue.
        let haltObserved = expectation(description: "halt observed")
        let task = Task {
            for await error in session.haltedErrors {
                if let error, error is StopError {
                    haltObserved.fulfill()
                    break
                }
            }
        }
        await fulfillment(of: [haltObserved], timeout: 2)
        task.cancel()

        do {
            _ = try await session.perform(FetchOperation(changeToken: nil))
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is StopError)
        }

        // The rejected operation must not have entered the frozen queue.
        let drained = expectation(description: "dispatch queue drained")
        session.dispatchQueue.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)

        XCTAssertFalse(session.state.hasWorkQueued)
    }

    func testPerformFetchThrowsOnDuplicateChangeToken() async {
        let session = makeStartedSession(handler: NeverCompletingMockOperationHandler())

        // First fetch queues and never completes; a second fetch with the
        // same (nil) change token is a detected duplicate.
        session.fetch(FetchOperation(changeToken: nil))

        let queued = expectation(description: "first fetch queued")
        session.dispatchQueue.async { queued.fulfill() }
        await fulfillment(of: [queued], timeout: 2)

        do {
            _ = try await session.perform(FetchOperation(changeToken: nil))
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is DuplicateFetchOperationError)
        }
    }

    func testPerformFetchCancellationThrowsCancellationError() async {
        let session = makeStartedSession(handler: NeverCompletingMockOperationHandler())

        let task = Task {
            try await session.perform(FetchOperation(changeToken: nil))
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testFirstFetchCompletionMatchesPredicate() async throws {
        let session = makeStartedSession(handler: SuccessfulMockOperationHandler())

        async let pendingMatch = session.firstFetchCompletion { _, response in
            !response.changedRecords.isEmpty
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        session.fetch(FetchOperation(changeToken: nil))

        let (_, response) = try await pendingMatch
        XCTAssertFalse(response.changedRecords.isEmpty)
    }

    func testPerformModifyThrowsTerminalWorkFailureUnmappedByErrorMiddleware() async {
        // A CKError whose code the ErrorMiddleware switch does not map (an
        // @unknown-default value, constructed from a raw error code CloudKit
        // does not define) passes through unmapped, so the raw workFailure
        // reaches SubjectMiddleware and the waiter throws the original
        // CloudKit error rather than a halt error.
        let unmappedErrorCode = 9999
        let unmappedError = CKError(_nsError: NSError(domain: CKErrorDomain, code: unmappedErrorCode))
        let session = makeStartedSession(handler: FailingMockOperationHandler(error: unmappedError))
        let operation = ModifyOperation(records: [makeTestRecord()], recordIDsToDelete: [], checkpointID: UUID(), userInfo: nil)

        do {
            _ = try await session.perform(operation)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as NSError).domain, CKErrorDomain)
            XCTAssertEqual((error as NSError).code, unmappedErrorCode)
        }
    }

    func testPerformModifyResolvesAfterConflictRequeue() async throws {
        let clientRecord = makeTestRecord()
        let serverRecord = CKRecord(recordType: "Test", recordID: clientRecord.recordID)
        let conflictError = CKError(
            .serverRecordChanged,
            userInfo: [
                CKRecordChangedErrorClientRecordKey: clientRecord,
                CKRecordChangedErrorServerRecordKey: serverRecord,
                CKRecordChangedErrorAncestorRecordKey: CKRecord(recordType: "Test", recordID: clientRecord.recordID),
            ]
        )

        // The first modify fails with a conflict carrying client and server
        // records; the session's resolver picks the server record, the
        // operation re-queues with a new id but the same checkpoint, and the
        // second attempt succeeds.
        let session = makeStartedConflictResolvingSession(handler: FailOnceMockOperationHandler(error: conflictError))
        let operation = ModifyOperation(records: [clientRecord], recordIDsToDelete: [], checkpointID: UUID(), userInfo: nil)

        let response = try await session.perform(operation)

        XCTAssertEqual(response.savedRecords.map(\.recordID), [serverRecord.recordID])
    }

    func testFirstFetchCompletionThrowsOnHalt() async {
        let session = makeStartedSession(handler: NeverCompletingMockOperationHandler())

        async let pendingMatch = session.firstFetchCompletion { _, _ in true }

        try? await Task.sleep(nanoseconds: 100_000_000)
        session.stop()

        do {
            _ = try await pendingMatch
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is StopError)
        }
    }
}

private let conflictTestZoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)

/// Like makeStartedSession, but resolves record conflicts by taking the
/// server record.
private func makeStartedConflictResolvingSession(handler: OperationHandler) -> CloudSyncSession {
    let session = CloudSyncSession(
        operationHandler: handler,
        zoneID: conflictTestZoneID,
        resolveConflict: { _, serverRecord in serverRecord },
        resolveExpiredChangeToken: { nil }
    )

    session.dispatch(event: .accountStatusChanged(.available))
    session.dispatch(event: .workSuccess(.createZone(CreateZoneOperation(zoneID: conflictTestZoneID)), .createZone(true)))
    session.dispatch(event: .workSuccess(.createSubscription(CreateSubscriptionOperation(zoneID: conflictTestZoneID)), .createSubscription(true)))

    return session
}

/// Fails the first fetch with the given error, then succeeds.
final class FailOnceFetchMockOperationHandler: OperationHandler {
    private let lock = NSLock()
    private let error: Error
    private var fetchCount = 0

    init(error: Error) {
        self.error = error
    }

    func handle(fetchOperation _: FetchOperation, completion: @escaping (Result<FetchOperation.Response, Error>) -> Void) {
        lock.lock()
        fetchCount += 1
        let shouldFail = fetchCount == 1
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) {
            if shouldFail {
                completion(.failure(self.error))
            } else {
                completion(
                    .success(
                        FetchOperation.Response(
                            changeToken: nil,
                            changedRecords: [makeTestRecord()],
                            deletedRecordIDs: [],
                            hasMore: false
                        )
                    )
                )
            }
        }
    }

    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) {
            completion(.success(ModifyOperation.Response(savedRecords: modifyOperation.records, deletedRecordIDs: [])))
        }
    }

    func handle(createZoneOperation _: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }

    func handle(createSubscriptionOperation _: CreateSubscriptionOperation, completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }
}
