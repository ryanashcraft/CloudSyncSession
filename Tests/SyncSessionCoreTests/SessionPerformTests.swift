@testable import SyncSessionCore
import XCTest

final class SessionPerformTests: XCTestCase {
    // MARK: Fetch

    func testFetchReturnsItsPage() async throws {
        let test = TestSession()

        test.startRunning()

        let response = try await test.session.perform(FetchOperation(changeToken: 7))

        XCTAssertEqual(response.changeToken, 8)
        XCTAssertFalse(response.hasMore)
        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testFetchReturnsTheFirstPageAndTheFollowUpGoesToTheStream() async throws {
        let test = TestSession()
        var completions = test.session.fetchCompletions.makeAsyncIterator()

        await test.reply(.succeedWithMore, .succeed)
        test.startRunning()

        let response = try await test.session.perform(FetchOperation(changeToken: 1))

        XCTAssertTrue(response.hasMore)
        XCTAssertEqual(response.changedRecords.count, 1)

        _ = await completions.next()

        let followUp = await completions.next()

        XCTAssertEqual(followUp?.0.changeToken, 2)
        XCTAssertEqual(followUp?.1.hasMore, false)
    }

    func testFetchFromAChangeTokenThatIsAlreadyQueuedThrowsAndQueuesNothing() async {
        let test = TestSession()

        test.session.fetch(FetchOperation(changeToken: 3))

        await assertThrows({ $0 is DuplicateFetchError }, "DuplicateFetchError") {
            try await test.session.perform(FetchOperation(changeToken: 3))
        }

        XCTAssertEqual(test.session.state.fetchQueue.count, 1)
    }

    func testFetchRetriedAfterAFailureReturnsOnce() async throws {
        let test = TestSession()

        await test.reply(.fail(.retry), .succeed)
        test.startRunning()

        let response = try await test.session.perform(FetchOperation(changeToken: 1))

        XCTAssertEqual(response.changeToken, 2)
    }

    // MARK: Modify

    func testModifyReturnsWhatWasSavedAndDeleted() async throws {
        let test = TestSession()

        test.startRunning()

        let response = try await test.session.perform(makeModify(saves: 2, deletes: 3))

        XCTAssertEqual(response.savedRecords.count, 2)
        XCTAssertEqual(response.deletedRecordIDs.count, 3)
        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testModifyWithoutACheckpointReturns() async throws {
        let test = TestSession()

        test.startRunning()

        let response = try await test.session.perform(makeModify(saves: 1, checkpointID: nil))

        XCTAssertEqual(response.savedRecords.count, 1)
    }

    func testModifyTooLargeForOneRequestReturnsEveryPiece() async throws {
        let test = TestSession()
        let operation = makeModify(saves: TestBackend.maxItemsPerModify + 1, deletes: 2)

        test.startRunning()

        let response = try await test.session.perform(operation)

        XCTAssertEqual(response.savedRecords, operation.records)
        XCTAssertEqual(response.deletedRecordIDs, operation.recordIDsToDelete)

        await test.nextRequest()
        await test.nextRequest()
        await test.nextRequest()
    }

    func testModifyTheServerSplitsReturnsBothHalves() async throws {
        let test = TestSession()
        let operation = makeModify(saves: 4)

        await test.reply(.fail(.split), .succeed, .succeed)
        test.startRunning()

        let response = try await test.session.perform(operation)

        XCTAssertEqual(response.savedRecords, operation.records)
    }

    func testModifyResentAfterAConflictReturnsWhatTheResendSaved() async throws {
        let test = TestSession()

        await test.reply(.fail(.resend(recordCount: 2)), .succeed)
        test.startRunning()

        let response = try await test.session.perform(makeModify(saves: 5))

        XCTAssertEqual(response.savedRecords.count, 2)
    }

    func testModifyResentWithNothingLeftToSaveStillReturns() async throws {
        let test = TestSession()

        await test.reply(.fail(.resend(recordCount: 0)), .succeed)
        test.startRunning()

        let response = try await test.session.perform(makeModify(saves: 1))

        XCTAssertEqual(response.savedRecords.count, 0)
    }

    func testModifyRetriedAfterAFailureReturnsOnce() async throws {
        let test = TestSession()

        await test.reply(.fail(.retry), .fail(.retry), .succeed)
        test.startRunning()

        let response = try await test.session.perform(makeModify(saves: 1))

        XCTAssertEqual(response.savedRecords.count, 1)
    }

    func testModifyIsAlsoReportedOnTheCompletionStream() async throws {
        let test = TestSession()
        var completions = test.session.modifyCompletions.makeAsyncIterator()
        let operation = makeModify()

        test.startRunning()

        _ = try await test.session.perform(operation)

        let completion = await completions.next()

        XCTAssertEqual(completion?.0.checkpointID, operation.checkpointID)
    }

    func testPerformWaitsForASessionThatIsNotReadyYet() async throws {
        let test = TestSession()
        let operation = makeModify()

        let performing = Task {
            try await test.session.perform(operation)
        }

        await test.waitForPerformToQueue()

        test.startRunning()

        let response = try await performing.value

        XCTAssertEqual(response.savedRecords.count, 1)
    }

    func testTwoPerformsEachGetTheirOwnResponse() async throws {
        let test = TestSession()

        test.startRunning()

        async let first = test.session.perform(makeModify(saves: 1))
        async let second = test.session.perform(makeModify(saves: 2))

        let responses = try await [first, second]

        XCTAssertEqual(responses.map(\.savedRecords.count), [1, 2])
    }

    // MARK: Task cancellation

    func testCancellingAQueuedPerformThrowsAndItsWorkIsNeverSent() async {
        let test = TestSession()
        let operation = makeModify()

        let performing = Task {
            try await test.session.perform(operation)
        }

        await test.waitForPerformToQueue()

        performing.cancel()

        await assertThrows({ $0 is CancellationError }, "CancellationError") {
            try await performing.value
        }

        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testCancellingAPerformWhoseRequestIsWithTheBackendLeavesTheRequestToFinish() async {
        let test = TestSession()
        var completions = test.session.modifyCompletions.makeAsyncIterator()
        let gate = await test.hold()
        let operation = makeModify()

        test.startRunning()

        let performing = Task {
            try await test.session.perform(operation)
        }

        await test.nextRequest()

        performing.cancel()

        await assertThrows({ $0 is CancellationError }, "CancellationError") {
            try await performing.value
        }

        gate.succeed()

        let completion = await completions.next()

        XCTAssertEqual(completion?.0.checkpointID, operation.checkpointID)
    }

    func testARequestLeftToFinishThatFailsIsNotSentAgain() async {
        let test = TestSession()
        let gate = await test.hold()
        let operation = makeModify()

        test.startRunning()

        let performing = Task {
            try await test.session.perform(operation)
        }

        await test.nextRequest()

        performing.cancel()
        _ = await performing.result

        gate.fail(.retry)

        await test.waitForEvent { event in
            if case .workFailure = event {
                return true
            }

            return false
        }

        // The failure and the removal of the work are one change, so a state read after the
        // event shows it.
        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testCancellingAPerformThatIsWaitingToRetryLetsTheWorkBehindItGoAtOnce() async {
        let test = TestSession(holdsRetryBackoff: true)

        await test.reply(.fail(.retry))
        test.startRunning()

        let performing = Task {
            try await test.session.perform(makeModify(saves: 1))
        }

        await test.nextRequest()
        await test.waitForEvent { event in
            if case .retry = event {
                return true
            }

            return false
        }

        test.session.modify(makeModify(saves: 2))
        performing.cancel()

        guard case let .modify(sent) = await test.nextRequest() else {
            return XCTFail("Expected a modify")
        }

        XCTAssertEqual(sent.records.count, 2)
    }

    // MARK: A fetch that fetch(_:) asked for as well

    func testAFetchThatFetchAlsoAskedForOutlivesACancelledPerform() async throws {
        let test = TestSession()
        var completions = test.session.fetchCompletions.makeAsyncIterator()

        let performing = Task {
            try await test.session.perform(FetchOperation(changeToken: 7))
        }

        await test.waitForPerformToQueue()

        test.session.fetch(FetchOperation(changeToken: 7))
        performing.cancel()
        _ = await performing.result

        XCTAssertEqual(test.session.state.fetchQueue.map(\.changeToken), [7])

        test.startRunning()

        let completion = await completions.next()

        XCTAssertEqual(completion?.0.changeToken, 7)
    }

    func testAFetchThatFetchAlsoAskedForOutlivesAHalt() async {
        let test = TestSession()
        let gate = await test.hold()

        test.startRunning()
        test.session.modify(makeModify())
        await test.nextRequest()

        let performing = Task {
            try await test.session.perform(FetchOperation(changeToken: 7))
        }

        await test.waitForPerformToQueue()

        test.session.fetch(FetchOperation(changeToken: 7))
        gate.fail(.halt)

        await assertThrows(isHalted, "halted") { try await performing.value }

        XCTAssertEqual(test.session.state.fetchQueue.map(\.changeToken), [7])
        XCTAssertNil(test.session.state.fetchQueue.first?.performID)
    }

    func testAFetchThatFetchAlsoAskedForStillAnswersThePerform() async throws {
        let test = TestSession()

        let performing = Task {
            try await test.session.perform(FetchOperation(changeToken: 7))
        }

        await test.waitForPerformToQueue()

        test.session.fetch(FetchOperation(changeToken: 7))
        test.startRunning()

        let response = try await performing.value

        XCTAssertEqual(response.changeToken, 8)
        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testAPerformFromATaskThatIsAlreadyCancelledQueuesNothing() async {
        let test = TestSession()
        let operation = makeModify()

        let performing = Task {
            await Task.yield()

            withUnsafeCurrentTask { $0?.cancel() }

            return try await test.session.perform(operation)
        }

        await assertThrows({ $0 is CancellationError }, "CancellationError") {
            try await performing.value
        }

        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    /// A checked continuation traps when it is resumed twice and logs when it is never resumed, so
    /// finishing this loop is the assertion.
    func testCancellationRacingCompletionResumesExactlyOnce() async {
        let test = TestSession()

        test.startRunning()

        for _ in 0 ..< 1000 {
            let gate = await test.hold()
            let operation = makeModify()

            let performing = Task {
                try await test.session.perform(operation)
            }

            await test.nextRequest()

            async let cancelled: Void = performing.cancel()
            async let answered: Void = gate.succeed()

            _ = await (cancelled, answered)
            _ = await performing.result
        }
    }
}
