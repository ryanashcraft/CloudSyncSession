import CloudKit
import XCTest

/// Behavior the session should have and currently does not.
///
/// Each test asserts the correct behavior inside `XCTExpectFailure`, so the suite stays green
/// while the defect exists. The expectations are strict: once a defect is fixed its test starts
/// reporting an unexpected pass, which is the cue to move it into `SessionBehaviorTests`.
final class SessionKnownDefectTests: XCTestCase {
    // MARK: Ordering

    /// A modify that is retried is moved behind every modify queued after it, so an older write
    /// can reach the server after a newer one.
    func testRetriedModifyKeepsItsPlaceInLine() {
        let harness = makeHarness()
        harness.handler.scriptModify(.fail(.networkUnavailable))
        harness.startRunning()

        harness.modify("A")
        harness.modify("B")
        harness.settle()

        XCTExpectFailure("A retried modify is requeued at the back of the queue", strict: true) {
            XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .modify("A", saves: 1), .modify("B", saves: 1)])
        }
    }

    /// A modify that is resent after conflict resolution is moved to the back in the same way.
    func testConflictedModifyKeepsItsPlaceInLine() {
        let harness = makeHarness(conflictPolicy: .clientWins)
        harness.handler.scriptModify(.partialFailure([0: .serverRecordChanged]))
        harness.startRunning()

        harness.modify("A")
        harness.modify("B")
        harness.settle()

        XCTExpectFailure("A conflict-resolved modify is requeued at the back of the queue", strict: true) {
            XCTAssertEqual(harness.workCalls, [.modify("A", saves: 1), .modify("A", saves: 1), .modify("B", saves: 1)])
        }
    }

    /// The pieces of an oversized modify are queued behind modifies submitted after it.
    func testOversizedModifyKeepsItsPlaceInLine() {
        let harness = makeHarness()
        harness.startRunning()

        harness.modify("big", saves: 800)
        harness.modify("small")
        harness.settle()

        XCTExpectFailure("The pieces of a split modify are queued behind later modifies", strict: true) {
            XCTAssertEqual(harness.workCalls, [.modify("big", saves: 400), .modify("big", saves: 400), .modify("small", saves: 1)])
        }
    }

    // MARK: Termination

    /// A single record the server rejects as too large is split into an empty request and the
    /// same record again, forever.
    func testSingleRecordRejectedAsTooLargeDoesNotLoop() {
        let harness = makeHarness()
        harness.handler.scriptModify(rule: { $0.saves > 0 ? .fail(.limitExceeded) : nil })
        harness.startRunning()

        harness.modify("A")

        XCTExpectFailure("A one-record modify that exceeds the size limit is split and resent without end", strict: true) {
            harness.settle(timeout: 2)

            XCTAssertLessThanOrEqual(harness.workCalls.count, 3)
        }
    }

    // MARK: Observation

    /// Observers are told about each event once per middleware instead of once.
    func testEachEventIsAnnouncedOnce() {
        let harness = makeHarness()
        harness.startRunning()
        let before = harness.eventCount(.doWork)

        harness.modify("A")
        harness.settle()

        XCTExpectFailure("Each event is published once per middleware in the chain", strict: true) {
            XCTAssertEqual(harness.eventCount(.doWork) - before, 1)
        }
    }

    // MARK: Fetch deduplication

    /// Two identical fetches requested back to back should collapse into one. The check and the
    /// enqueue are separate steps, so both usually get through.
    ///
    /// Not strict: the outcome depends on thread timing, and the correct result does occur.
    func testBackToBackIdenticalFetchesAreCollapsed() {
        let harness = makeHarness()
        harness.startRunning()

        harness.fetch()
        harness.fetch()
        harness.settle()

        XCTExpectFailure("The duplicate-fetch check races with the enqueue it guards", strict: false) {
            XCTAssertEqual(harness.workCalls, [.fetch])
        }
    }

    // MARK: Lifetime

    /// The session and its middleware hold each other strongly, so a session is never freed.
    func testSessionIsReleasedWhenDropped() {
        XCTExpectFailure("The session and its middleware form a retain cycle", strict: true) {
            XCTAssertTrue(SessionHarness.sessionIsReleasedWhenDropped())
        }
    }
}
