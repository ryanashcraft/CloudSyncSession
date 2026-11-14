@testable import SyncSessionCore
import XCTest

final class SessionPerformInterruptionTests: XCTestCase {
    // MARK: Halt

    func testModifyThrowsWhenItsOwnFailureHaltsTheSessionAndIsNotSentAgain() async {
        let test = TestSession()

        await test.reply(.fail(.halt))
        test.startRunning()

        await assertThrows(isHalted, "halted") {
            try await test.session.perform(makeModify())
        }

        XCTAssertTrue(test.session.state.isHalted)
        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testFetchThrowsWhenItsOwnFailureHaltsTheSessionAndIsNotSentAgain() async {
        let test = TestSession()

        await test.reply(.fail(.halt))
        test.startRunning()

        await assertThrows(isHalted, "halted") {
            try await test.session.perform(FetchOperation(changeToken: 1))
        }

        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testPerformThrowsWhenOtherWorkHaltsTheSession() async {
        let test = TestSession()
        let gate = await test.hold()
        let blocker = makeModify()
        let operation = makeModify()

        test.startRunning()
        test.session.modify(blocker)
        await test.nextRequest()

        let performing = Task {
            try await test.session.perform(operation)
        }

        await test.waitForPerformToQueue()

        gate.fail(.halt)

        await assertThrows(isHalted, "halted") {
            try await performing.value
        }

        XCTAssertEqual(test.session.state.modifyQueue.map(\.id), [blocker.id], "The work that halted keeps its place; the perform's work is gone")
    }

    func testEveryPerformThrowsOnOneHalt() async {
        let test = TestSession()
        let gate = await test.hold()

        test.startRunning()

        let modifying = Task {
            try await test.session.perform(makeModify())
        }

        await test.nextRequest()

        let fetching = Task {
            try await test.session.perform(FetchOperation(changeToken: 1))
        }

        await test.waitForEvent { event in
            if case .doWork(.fetch) = event {
                return true
            }

            return false
        }

        gate.fail(.halt)

        await assertThrows(isHalted, "halted") { try await modifying.value }
        await assertThrows(isHalted, "halted") { try await fetching.value }

        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testPerformOnAHaltedSessionThrowsAtOnceAndQueuesNothing() async {
        let test = TestSession()

        await test.reply(.fail(.halt))
        test.startRunning()
        test.session.modify(makeModify())
        await test.waitForHalt()

        await assertThrows(isHalted, "halted") {
            try await test.session.perform(makeModify())
        }

        await assertThrows(isHalted, "halted") {
            try await test.session.perform(FetchOperation(changeToken: 1))
        }

        XCTAssertEqual(test.session.state.modifyQueue.count, 1)
        XCTAssertEqual(test.session.state.fetchQueue.count, 0)
    }

    func testModifyInPiecesThrowsWhenALaterPieceHaltsAndNothingOfItIsLeft() async {
        let test = TestSession()

        await test.reply(.succeed, .fail(.halt))
        test.startRunning()

        await assertThrows(isHalted, "halted") {
            try await test.session.perform(makeModify(saves: TestBackend.maxItemsPerModify + 1))
        }

        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testAfterAHaltTheSessionResumesWithoutThePerformsWork() async throws {
        let test = TestSession()

        await test.reply(.fail(.halt))
        test.startRunning()

        _ = try? await test.session.perform(makeModify(saves: 3))

        test.session.start()

        let response = try await test.session.perform(makeModify(saves: 1))

        XCTAssertEqual(response.savedRecords.count, 1)

        await test.nextRequest()

        guard case let .modify(sent) = await test.nextRequest() else {
            return XCTFail("Expected a modify")
        }

        XCTAssertEqual(sent.records.count, 1, "The halted perform's three records should not have been sent again")
    }

    // MARK: Stop

    func testPerformQueuedBehindOtherWorkThrowsOnStopAndIsNeverSent() async {
        let test = TestSession()

        _ = await test.hold()
        test.startRunning()
        test.session.modify(makeModify())
        await test.nextRequest()

        let modifying = Task {
            try await test.session.perform(makeModify())
        }

        await test.waitForPerformToQueue()

        let fetching = Task {
            try await test.session.perform(FetchOperation(changeToken: 1))
        }

        await test.waitForPerformToQueue()

        test.session.stop()

        await assertThrows(isStopped, "stopped") { try await modifying.value }
        await assertThrows(isStopped, "stopped") { try await fetching.value }

        XCTAssertEqual(test.session.state.modifyQueue.count, 1)
        XCTAssertEqual(test.session.state.fetchQueue.count, 0)
    }

    func testModifyThrowsOnStopWhenItsRequestIsCancelledAndIsNeverSentAgain() async {
        let test = TestSession()

        _ = await test.hold()
        test.startRunning()

        let performing = Task {
            try await test.session.perform(makeModify())
        }

        await test.nextRequest()

        test.session.stop()

        await assertThrows(isStopped, "stopped") { try await performing.value }

        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testFetchThrowsOnStopWhenItsRequestIsCancelledAndIsNeverSentAgain() async {
        let test = TestSession()

        _ = await test.hold()
        test.startRunning()

        let performing = Task {
            try await test.session.perform(FetchOperation(changeToken: 1))
        }

        await test.nextRequest()

        test.session.stop()

        await assertThrows(isStopped, "stopped") { try await performing.value }

        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testModifyReturnsWhenTheServerTookItsRequestDespiteTheStop() async throws {
        let test = TestSession()
        let gate = await test.holdThroughCancellation()

        test.startRunning()

        let performing = Task {
            try await test.session.perform(makeModify(saves: 2))
        }

        await test.nextRequest()

        test.session.stop()
        gate.succeed()

        let response = try await performing.value

        XCTAssertEqual(response.savedRecords.count, 2)
        XCTAssertTrue(test.session.state.isHalted)
    }

    func testModifyInPiecesThrowsOnStopEvenWhenThePieceInFlightSucceeds() async {
        let test = TestSession()
        let gate = await test.holdThroughCancellation()

        test.startRunning()

        let performing = Task {
            try await test.session.perform(makeModify(saves: TestBackend.maxItemsPerModify + 1))
        }

        await test.nextRequest()

        test.session.stop()
        gate.succeed()

        await assertThrows(isStopped, "stopped") { try await performing.value }

        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testPerformBetweenStopAndStartThrowsAtOnce() async {
        let test = TestSession()

        test.startRunning()
        test.session.stop()

        await assertThrows(isStopped, "stopped") {
            try await test.session.perform(makeModify())
        }

        XCTAssertTrue(test.session.state.modifyQueue.isEmpty)
    }

    func testPerformSurvivesAStopThatIsFollowedByAStartBeforeItsRequestWindsDown() async throws {
        let test = TestSession()
        let gate = await test.holdThroughCancellation()

        test.startRunning()

        let performing = Task {
            try await test.session.perform(makeModify())
        }

        await test.nextRequest()

        test.session.stop()
        test.session.start()
        gate.fail(.retry)

        let response = try await performing.value

        XCTAssertEqual(response.savedRecords.count, 1)
    }

    // MARK: Reset

    func testPerformQueuedThrowsOnReset() async {
        let test = TestSession()

        let modifying = Task {
            try await test.session.perform(makeModify())
        }

        await test.waitForPerformToQueue()

        let fetching = Task {
            try await test.session.perform(FetchOperation(changeToken: 1))
        }

        await test.waitForPerformToQueue()

        test.session.reset()

        await assertThrows(isReset, "reset") { try await modifying.value }
        await assertThrows(isReset, "reset") { try await fetching.value }

        XCTAssertFalse(test.session.state.hasWorkQueued)
    }

    func testModifyThrowsOnResetWhileItsRequestIsStillWithTheBackend() async {
        let test = TestSession()
        let gate = await test.holdThroughCancellation()

        test.startRunning()

        let performing = Task {
            try await test.session.perform(makeModify())
        }

        await test.nextRequest()

        test.session.reset()

        await assertThrows(isReset, "reset") { try await performing.value }

        gate.succeed()
    }

    func testFetchThrowsOnResetWhileItsRequestIsStillWithTheBackend() async {
        let test = TestSession()
        let gate = await test.holdThroughCancellation()

        test.startRunning()

        let performing = Task {
            try await test.session.perform(FetchOperation(changeToken: 1))
        }

        await test.nextRequest()

        test.session.reset()

        await assertThrows(isReset, "reset") { try await performing.value }

        gate.succeed()
    }

    func testPerformAfterAResetWaitsForTheSessionToStartAgain() async throws {
        let test = TestSession()

        test.startRunning()
        test.session.stop()
        test.session.reset()

        let performing = Task {
            try await test.session.perform(makeModify())
        }

        await test.waitForPerformToQueue()

        test.startRunning()

        let response = try await performing.value

        XCTAssertEqual(response.savedRecords.count, 1)
    }

    // MARK: Work that no perform owns

    func testWorkQueuedWithoutPerformIsKeptThroughAnInterruption() async throws {
        let test = TestSession()
        var completions = test.session.modifyCompletions.makeAsyncIterator()

        _ = await test.hold()
        test.startRunning()

        let performing = Task {
            try await test.session.perform(makeModify(saves: 1))
        }

        await test.nextRequest()

        test.session.modify(makeModify(saves: 2))
        test.session.stop()

        _ = await performing.result

        test.session.start()

        let completion = await completions.next()

        XCTAssertEqual(completion?.1.savedRecords.count, 2)
    }
}
