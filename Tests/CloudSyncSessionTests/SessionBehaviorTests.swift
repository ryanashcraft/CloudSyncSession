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
}
