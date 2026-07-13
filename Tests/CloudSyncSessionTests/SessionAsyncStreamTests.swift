@testable import CloudSyncSession
import CloudKit
import XCTest

private let testZoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)

func makeStartedSession(handler: OperationHandler) -> CloudSyncSession {
    let session = CloudSyncSession(
        operationHandler: handler,
        zoneID: testZoneID,
        resolveConflict: { _, _ in nil },
        resolveExpiredChangeToken: { nil }
    )

    session.dispatch(event: .accountStatusChanged(.available))
    session.dispatch(event: .workSuccess(.createZone(CreateZoneOperation(zoneID: testZoneID)), .createZone(true)))
    session.dispatch(event: .workSuccess(.createSubscription(CreateSubscriptionOperation(zoneID: testZoneID)), .createSubscription(true)))

    return session
}

final class SessionAsyncStreamTests: XCTestCase {
    func testFetchWorkCompletionsMulticastsToConcurrentStreams() async {
        let session = makeStartedSession(handler: SuccessfulMockOperationHandler())
        let firstStream = session.fetchWorkCompletions
        let secondStream = session.fetchWorkCompletions

        session.fetch(FetchOperation(changeToken: nil))

        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()

        let firstCompletion = await firstIterator.next()
        let secondCompletion = await secondIterator.next()

        XCTAssertNotNil(firstCompletion)
        XCTAssertNotNil(secondCompletion)
        XCTAssertEqual(firstCompletion?.1.changedRecords.count, secondCompletion?.1.changedRecords.count)
    }

    func testModifyWorkCompletionsObservesDispatchedModify() async {
        let session = makeStartedSession(handler: SuccessfulMockOperationHandler())
        let stream = session.modifyWorkCompletions

        let record = makeTestRecord()
        session.modify(ModifyOperation(records: [record], recordIDsToDelete: [], checkpointID: UUID(), userInfo: nil))

        var iterator = stream.makeAsyncIterator()
        let completion = await iterator.next()

        XCTAssertEqual(completion?.1.savedRecords.first?.recordID, record.recordID)
    }

    func testHaltedErrorsReplaysCurrentValueAndObservesHalt() async {
        let session = makeStartedSession(handler: NeverCompletingMockOperationHandler())

        var freshIterator = session.haltedErrors.makeAsyncIterator()

        // The outer optional is the iterator's end-of-stream; the inner
        // optional is the element. The replayed current value must be a
        // present element whose value is nil (not halted).
        guard case let .some(initialValue) = await freshIterator.next() else {
            return XCTFail("expected a replayed element")
        }
        XCTAssertNil(initialValue)

        session.stop()

        guard case let .some(haltedValue) = await freshIterator.next() else {
            return XCTFail("expected a second element after halt")
        }
        XCTAssertTrue(haltedValue is StopError)
    }

    func testAccountStatusesReplaysLatest() async {
        let session = makeStartedSession(handler: NeverCompletingMockOperationHandler())

        // The started session already dispatched an available status. A stream
        // created afterwards must replay it.
        let expectation = expectation(description: "replayed status")

        let task = Task {
            for await status in session.accountStatuses {
                if status == .available {
                    expectation.fulfill()
                    break
                }
            }
        }

        await fulfillment(of: [expectation], timeout: 2)
        task.cancel()
    }

    func testStatesReplaysCurrentStateFirst() async {
        let session = makeStartedSession(handler: NeverCompletingMockOperationHandler())

        // Wait for the three startup dispatches to settle so the replayed
        // state is deterministic.
        let settled = expectation(description: "settled")
        session.dispatchQueue.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)

        var iterator = session.states.makeAsyncIterator()
        let first = await iterator.next()

        XCTAssertEqual(first?.hasGoodAccountStatus, true)
        XCTAssertEqual(first?.hasCreatedZone, true)
        XCTAssertEqual(first?.hasCreatedSubscription, true)
    }

    func testEventsStreamDoesNotReplayAndObservesNewEvents() async {
        let session = makeStartedSession(handler: NeverCompletingMockOperationHandler())

        // Let the startup events flush so they cannot land in the new stream.
        let settled = expectation(description: "settled")
        session.dispatchQueue.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)

        let stream = session.events
        session.dispatch(event: .noop)

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()

        if case .noop = first {
            // The first observed element is the event dispatched after
            // creation, not a replay of the startup events.
        } else {
            XCTFail("expected .noop as the first element, got \(String(describing: first))")
        }
    }
}
