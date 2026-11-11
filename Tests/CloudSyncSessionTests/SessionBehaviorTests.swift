import CloudKit
import XCTest

/// What a sync session does, observed only from outside: the requests that reach the operation
/// handler and the completions the session reports.
///
/// These tests deliberately do not import the library. Everything goes through `SessionHarness`,
/// so they describe behavior that must hold however the session is implemented.
final class SessionBehaviorTests: XCTestCase {
    // MARK: Startup

    func testStartCreatesTheZoneThenTheSubscription() {
        let harness = makeHarness()

        harness.startRunning()

        XCTAssertEqual(harness.calls, [.createZone, .createSubscription])
    }

    // MARK: Modifying

    func testModifyIsSentAndReported() {
        let harness = makeHarness()
        harness.startRunning()

        harness.modify("A", saves: 2, deletes: 1, checkpoint: true)
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 2, deletes: 1)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 2, deleted: 1, checkpointed: true)])
    }

    func testModifiesRunOneAtATimeInSubmissionOrder() {
        let harness = makeHarness()
        harness.startRunning()

        harness.modify("A")
        harness.modify("B")
        harness.modify("C")
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .modify("B", saves: 1), .modify("C", saves: 1)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 1), .modify("B", saved: 1), .modify("C", saved: 1)])
        XCTAssertEqual(harness.handler.maxConcurrentCalls, 1)
    }

    func testQueuedModifiesRunBeforeQueuedFetches() {
        let harness = makeHarness()

        harness.fetch()
        harness.modify("A")
        harness.modify("B")
        harness.startRunning()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .modify("B", saves: 1), .fetch])
    }

    // MARK: Fetching

    func testFetchContinuesWhileMoreIsComing() {
        let harness = makeHarness()
        harness.handler.scriptFetch(.page(changed: 3, hasMore: true), .page(changed: 1, hasMore: false))
        harness.startRunning()

        harness.fetch()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.fetch, .fetch])
        XCTAssertEqual(harness.completions, [.fetch(changed: 3, hasMore: true), .fetch(changed: 1, hasMore: false)])
    }

    func testMissingZoneIsRecreatedAndTheFetchRetried() {
        let harness = makeHarness()
        harness.handler.scriptFetch(.fail(.zoneNotFound))
        harness.startRunning()

        harness.fetch()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.fetch, .createZone, .fetch])
        XCTAssertEqual(harness.completions, [.fetch(changed: 0, hasMore: false)])
        XCTAssertFalse(harness.isHalted)
    }

    // MARK: Failures

    func testTransientFailureIsRetried() {
        let harness = makeHarness()
        harness.handler.scriptModify(.fail(.networkUnavailable))
        harness.startRunning()

        harness.modify("A")
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .modify("A", saves: 1)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 1)])
        XCTAssertFalse(harness.isHalted)
    }

    func testUnrecoverableFailureHaltsAndKeepsTheWorkForTheNextStart() {
        let harness = makeHarness()
        harness.handler.scriptModify(.fail(.notAuthenticated))
        harness.startRunning()

        harness.modify("A")
        harness.settle()

        XCTAssertTrue(harness.isHalted)
        XCTAssertEqual(harness.haltCode, .notAuthenticated)
        XCTAssertTrue(harness.hasWorkQueued)
        XCTAssertEqual(harness.completions, [])

        harness.start()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .modify("A", saves: 1)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 1)])
        XCTAssertFalse(harness.isHalted)
    }

    func testWorkQueuedWhileStoppedWaitsForStart() {
        let harness = makeHarness()
        harness.startRunning()
        harness.stop()
        harness.settle()

        harness.modify("A")
        harness.settle()

        XCTAssertEqual(harness.workCalls, [])
        XCTAssertEqual(harness.completions, [])

        harness.start()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 1)])
    }

    // MARK: Splitting

    func testOversizedModifyIsSentInPiecesWithTheCheckpointOnTheLast() {
        let harness = makeHarness()
        harness.startRunning()

        harness.modify("A", saves: 850, deletes: 30, checkpoint: true)
        harness.settle()

        let pieces = harness.workCalls.compactMap { call -> (saves: Int, deletes: Int)? in
            guard case let .modify("A", saves, deletes) = call else {
                return nil
            }

            return (saves, deletes)
        }

        XCTAssertEqual(pieces.count, harness.workCalls.count, "Only pieces of A should have been sent")
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.saves + $0.deletes <= 400 }, "No request may exceed 400 items: \(harness.workCalls)")
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.saves }, 850)
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.deletes }, 30)

        let checkpointFlags = harness.completions.map { completion -> Bool in
            guard case let .modify(_, _, _, checkpointed) = completion else {
                return false
            }

            return checkpointed
        }

        XCTAssertEqual(checkpointFlags.count, pieces.count)
        XCTAssertEqual(checkpointFlags.filter { $0 }.count, 1, "The checkpoint must be reported exactly once")
        XCTAssertEqual(checkpointFlags.last, true, "The checkpoint must be reported with the final piece")
    }

    func testRequestRejectedAsTooLargeIsSplitInHalf() {
        let harness = makeHarness()
        harness.handler.scriptModify(.fail(.limitExceeded))
        harness.startRunning()

        harness.modify("A", saves: 100, checkpoint: true)
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 100), .modify("A", saves: 50), .modify("A", saves: 50)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 50), .modify("A", saved: 50, checkpointed: true)])
    }

    // MARK: Conflicts

    func testConflictIsResolvedAndTheWholeBatchResent() {
        let harness = makeHarness(conflictPolicy: .clientWins)
        harness.handler.scriptModify(.partialFailure([0: .serverRecordChanged]))
        harness.startRunning()

        harness.modify("A", saves: 3, checkpoint: true)
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 3), .modify("A", saves: 3)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 3, checkpointed: true)])
        XCTAssertEqual(harness.savedServerCopyCount, 0, "The client's fields should have replaced the server's")
        XCTAssertFalse(harness.isHalted)
    }

    func testConflictTheServerWinsStillResendsTheServerCopy() {
        let harness = makeHarness(conflictPolicy: .serverWins)
        harness.handler.scriptModify(.partialFailure([0: .serverRecordChanged]))
        harness.startRunning()

        harness.modify("A", saves: 3)
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 3), .modify("A", saves: 3)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 3)])
        XCTAssertEqual(harness.savedServerCopyCount, 1)
    }

    func testConflictThatCannotBeResolvedHalts() {
        let harness = makeHarness(conflictPolicy: .unresolvable)
        harness.handler.scriptModify(.partialFailure([0: .serverRecordChanged]))
        harness.startRunning()

        harness.modify("A", saves: 3)
        harness.settle()

        XCTAssertTrue(harness.isHalted)
        XCTAssertEqual(harness.haltCode, .partialFailure)
        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 3)])
        XCTAssertEqual(harness.completions, [])
    }

    func testRecordTheServerNoLongerHasIsLeftOutOfTheResend() {
        let harness = makeHarness()
        harness.handler.scriptModify(.partialFailure([1: .unknownItem]))
        harness.startRunning()

        harness.modify("A", saves: 3)
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 3), .modify("A", saves: 2)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 2)])
        XCTAssertFalse(harness.isHalted)
    }

    func testPartialFailureWithoutPerRecordErrorsHalts() {
        let harness = makeHarness()
        harness.handler.scriptModify(.fail(.partialFailure))
        harness.startRunning()

        harness.modify("A")
        harness.settle()

        XCTAssertTrue(harness.isHalted)
        XCTAssertEqual(harness.haltCode, .partialFailure)
        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1)])
        XCTAssertTrue(harness.hasWorkQueued)
    }

    func testErrorCodeTheLibraryDoesNotKnowHaltsAndKeepsTheWork() throws {
        let unknownCode = try XCTUnwrap(CKError.Code(rawValue: 9999))
        let harness = makeHarness()
        harness.handler.scriptModify(.fail(unknownCode))
        harness.startRunning()

        harness.modify("A")
        harness.settle()

        XCTAssertTrue(harness.isHalted)
        XCTAssertEqual(harness.haltCode, unknownCode)
        XCTAssertTrue(harness.hasWorkQueued)
        XCTAssertEqual(harness.completions, [])
    }

    // MARK: Retrying

    func testRetriesWaitLongerEachTimeAndHaltAfterFive() {
        let harness = makeHarness()
        harness.handler.scriptModify(rule: { _ in .fail(.networkUnavailable) })
        harness.startRunning()

        harness.modify("A")
        harness.modify("B")
        harness.settle()

        XCTAssertEqual(harness.workCalls, Array(repeating: .modify("A", saves: 1), count: 6), "One attempt and five retries, with B still waiting")
        XCTAssertEqual(harness.retryBackoffs, [0, 1, 4, 9, 16])
        XCTAssertTrue(harness.isHalted)
        XCTAssertEqual(harness.haltCode, .networkUnavailable)
        XCTAssertTrue(harness.hasWorkQueued)
        XCTAssertEqual(harness.completions, [])

        harness.handler.scriptModify(rule: { _ in nil })
        harness.start()
        harness.settle()

        XCTAssertEqual(harness.completions, [.modify("A", saved: 1), .modify("B", saved: 1)])
        XCTAssertFalse(harness.isHalted)
    }

    // MARK: Keeping order

    func testRetriedModifyKeepsItsPlaceInLine() {
        let harness = makeHarness()
        harness.handler.scriptModify(.fail(.networkUnavailable))
        harness.startRunning()

        harness.modify("A")
        harness.modify("B")
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .modify("A", saves: 1), .modify("B", saves: 1)])
    }

    func testConflictedModifyKeepsItsPlaceInLine() {
        let harness = makeHarness(conflictPolicy: .clientWins)
        harness.handler.scriptModify(.partialFailure([0: .serverRecordChanged]))
        harness.startRunning()

        harness.modify("A")
        harness.modify("B")
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .modify("A", saves: 1), .modify("B", saves: 1)])
    }

    func testOversizedModifyKeepsItsPlaceInLine() {
        let harness = makeHarness()
        harness.startRunning()

        harness.modify("big", saves: 800)
        harness.modify("small")
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("big", saves: 400), .modify("big", saves: 400), .modify("small", saves: 1)])
    }

    func testMissingZoneIsRecreatedBeforeAnyQueuedModifyGoesOut() {
        let harness = makeHarness()
        harness.handler.scriptModify(.fail(.zoneNotFound))
        harness.startRunning()

        harness.modify("A")
        harness.modify("B")
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .createZone, .modify("A", saves: 1), .modify("B", saves: 1)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 1), .modify("B", saved: 1)])
        XCTAssertFalse(harness.isHalted)
    }

    // MARK: Requests that cannot be made smaller

    func testSingleRecordRejectedAsTooLargeDoesNotLoop() {
        let harness = makeHarness()
        harness.handler.scriptModify(rule: { $0.saves > 0 ? .fail(.limitExceeded) : nil })
        harness.startRunning()

        harness.modify("A")
        harness.settle(timeout: 2)

        XCTAssertLessThanOrEqual(harness.workCalls.count, 3)
        XCTAssertTrue(harness.isHalted)
        XCTAssertEqual(harness.haltCode, .limitExceeded)
        XCTAssertTrue(harness.hasWorkQueued)
    }

    func testOneSaveAndOneDeletionRejectedAsTooLargeAreSentSeparately() {
        let harness = makeHarness()
        harness.handler.scriptModify(rule: { $0.saves + $0.deletes > 1 ? .fail(.limitExceeded) : nil })
        harness.startRunning()

        harness.modify("A", saves: 1, deletes: 1, checkpoint: true)
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1, deletes: 1), .modify("A", saves: 1), .modify("A", saves: 0, deletes: 1)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 1), .modify("A", saved: 0, deleted: 1, checkpointed: true)])
        XCTAssertFalse(harness.isHalted)
    }

    // MARK: Observation

    func testEachEventIsAnnouncedOnce() {
        let harness = makeHarness()
        harness.startRunning()
        let before = harness.eventCount(.doWork)

        harness.modify("A")
        harness.settle()

        XCTAssertEqual(harness.eventCount(.doWork) - before, 1)
    }

    // MARK: Fetch deduplication

    func testBackToBackIdenticalFetchesAreCollapsed() {
        let harness = makeHarness()
        harness.startRunning()

        harness.fetch()
        harness.fetch()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.fetch])
    }

    // MARK: Account status

    func testWorkWaitsUntilTheAccountIsAvailable() {
        let harness = makeHarness()
        harness.setAccountAvailable(false)

        harness.start()
        harness.modify("A")
        harness.settle()

        XCTAssertEqual(harness.calls, [])

        harness.setAccountAvailable(true)
        harness.settle()

        XCTAssertEqual(harness.calls, [.createZone, .createSubscription, .modify("A", saves: 1)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 1)])
    }

    func testAccountBecomingAvailableDoesNotRestartAHaltedSession() {
        let harness = makeHarness()
        harness.handler.scriptModify(.fail(.notAuthenticated))
        harness.startRunning()

        harness.modify("A")
        harness.settle()
        harness.setAccountAvailable(true)
        harness.settle()

        XCTAssertTrue(harness.isHalted)
        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1)])
    }

    func testStartingTwiceSetsUpTheZoneOnce() {
        let harness = makeHarness()

        harness.start()
        harness.start()
        harness.settle()

        XCTAssertEqual(harness.calls, [.createZone, .createSubscription])
    }

    // MARK: Stopping and resetting

    func testStoppingBeforeQueuedWorkIsSentKeepsItForTheNextStart() {
        let harness = makeHarness()
        harness.startRunning()
        harness.holdWorkDelay()

        harness.modify("A")
        harness.waitUntilWaiting()
        harness.stop()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [])
        XCTAssertTrue(harness.hasWorkQueued)

        harness.releaseWaits()
        harness.start()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 1)])
    }

    func testResettingDuringTheWaitBeforeARetryAbandonsTheRetry() {
        let harness = makeHarness()
        harness.handler.scriptModify(.fail(.networkUnavailable))
        harness.startRunning()
        harness.holdRetryBackoff()

        harness.modify("A")
        harness.waitUntilWaiting()
        harness.reset()
        harness.settle()
        harness.releaseWaits()

        XCTAssertFalse(harness.hasWorkQueued)

        harness.setAccountAvailable(true)
        harness.start()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .createZone, .createSubscription])
        XCTAssertEqual(harness.completions, [])
    }

    func testFailureThatArrivesAfterStoppingIsNotRetried() {
        let harness = makeHarness()
        harness.handler.scriptModify(.fail(.networkUnavailable))
        harness.startRunning()
        harness.handler.holdReplies()

        harness.modify("A")
        harness.waitUntilReplyIsHeld()
        harness.stop()
        harness.handler.releaseReplies()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1)])
        XCTAssertEqual(harness.retryBackoffs, [])
        XCTAssertTrue(harness.hasWorkQueued)

        harness.start()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .modify("A", saves: 1)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 1)])
    }

    func testFailureThatArrivesAfterStoppingAndStartingAgainIsRetriedAfterItsWait() {
        let harness = makeHarness()
        harness.handler.scriptModify(.fail(.networkUnavailable))
        harness.startRunning()
        harness.handler.holdReplies()

        harness.modify("A")
        harness.modify("B")
        harness.waitUntilReplyIsHeld()
        harness.stop()
        harness.start()
        harness.handler.releaseReplies()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .modify("A", saves: 1), .modify("B", saves: 1)])
        XCTAssertEqual(harness.retryBackoffs, [0], "The failure must be handled as a retry, with its wait, not resent at once")
        XCTAssertEqual(harness.completions, [.modify("A", saved: 1), .modify("B", saved: 1)])
        XCTAssertEqual(harness.handler.maxConcurrentCalls, 1)
    }

    func testMissingZoneReportedAfterStoppingDoesNotRecreateTheZone() {
        let harness = makeHarness()
        harness.handler.scriptFetch(.fail(.zoneNotFound))
        harness.startRunning()
        harness.handler.holdReplies()

        harness.fetch()
        harness.waitUntilReplyIsHeld()
        harness.stop()
        harness.handler.releaseReplies()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.fetch])
    }

    func testSuccessThatArrivesAfterStoppingIsStillReported() {
        let harness = makeHarness()
        harness.startRunning()
        harness.handler.holdReplies()

        harness.modify("A")
        harness.waitUntilReplyIsHeld()
        harness.stop()
        harness.handler.releaseReplies()
        harness.settle()

        XCTAssertEqual(harness.completions, [.modify("A", saved: 1)])
        XCTAssertFalse(harness.hasWorkQueued)

        harness.start()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1)], "Work the server already has must not be sent again")
    }

    func testResultThatArrivesAfterResettingIsDropped() {
        let harness = makeHarness()
        harness.startRunning()
        harness.handler.holdReplies()

        harness.modify("A")
        harness.waitUntilReplyIsHeld()
        harness.reset()
        harness.handler.releaseReplies()
        harness.settle()

        XCTAssertEqual(harness.completions, [])
        XCTAssertFalse(harness.hasWorkQueued)
    }

    func testStopAndWaitReturnsOnlyOnceTheOperationUnderWayHasFinished() {
        let harness = makeHarness()
        harness.startRunning()
        harness.handler.holdReplies()

        harness.modify("A")
        harness.waitUntilReplyIsHeld()
        let hasReturned = harness.beginStopAndWait()
        harness.idle()

        XCTAssertTrue(harness.isHalted)
        XCTAssertFalse(hasReturned(), "stopAndWait returned while an operation was still with the handler")

        harness.handler.releaseReplies()
        harness.waitUntil("stopAndWait has returned") { hasReturned() }

        XCTAssertTrue(harness.handler.isIdle)
    }

    func testStopAndWaitReturnsStraightAwayWhenNothingIsUnderWay() {
        let harness = makeHarness()
        harness.startRunning()

        let hasReturned = harness.beginStopAndWait()

        harness.waitUntil("stopAndWait has returned") { hasReturned() }
        XCTAssertTrue(harness.isHalted)
    }

    func testRestartingWhileAnOperationIsUnderWayDoesNotSendASecondOne() {
        let harness = makeHarness()
        harness.startRunning()
        harness.handler.holdReplies()

        harness.modify("A")
        harness.modify("B")
        harness.waitUntilReplyIsHeld()
        harness.stop()
        harness.start()
        harness.idle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1)])

        harness.handler.releaseReplies()
        harness.settle()

        XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .modify("B", saves: 1)])
        XCTAssertEqual(harness.completions, [.modify("A", saved: 1), .modify("B", saved: 1)])
        XCTAssertEqual(harness.handler.maxConcurrentCalls, 1)
    }

    // MARK: Lifetime

    func testSessionIsReleasedWhenDropped() {
        XCTAssertTrue(SessionHarness.sessionIsReleasedWhenDropped())
    }

    func testSessionIsReleasedAfterWorking() {
        XCTAssertTrue(SessionHarness.sessionIsReleasedAfterWorking())
    }
}
