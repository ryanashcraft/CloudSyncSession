@testable import SyncSessionCore
import XCTest

/// The rules that decide which work is next and how the queues change when an attempt at work
/// ends. These are plain value changes on `SyncState`, checked here without a session.
final class SyncStateTests: XCTestCase {
    // MARK: What may run

    func testNoWorkRunsWhileTheAccountStatusIsUnknown() {
        var state = SyncState()

        state.enqueue(makeModify())

        XCTAssertNil(state.currentWork)
    }

    func testOnlySetupRunsUntilTheZoneAndSubscriptionExist() {
        var state = SyncState()
        state.hasGoodAccountStatus = true

        state.enqueue(makeModify())

        XCTAssertNil(state.currentWork)

        let createZone = SyncWork.setup(SetupOperation(step: .zone))
        state.enqueue(createZone)

        XCTAssertEqual(state.currentWork?.id, createZone.id)
    }

    func testModifiesAndFetchesRunOnceSetupIsDone() {
        var state = makeRunningState()
        let modify = makeModify()

        state.enqueue(modify)

        XCTAssertEqual(state.currentWork?.id, modify.id)
    }

    func testNothingRunsWhileHalted() {
        var state = makeRunningState()
        state.enqueue(makeModify())

        state.isHalted = true

        XCTAssertNil(state.currentWork)
        XCTAssertNil(state.operationMode)
        XCTAssertNotNil(state.lastHaltedDate)

        state.isHalted = false

        XCTAssertNotNil(state.currentWork)
        XCTAssertNil(state.lastHaltedDate)
    }

    // MARK: What runs first

    func testZoneIsCreatedBeforeTheSubscription() {
        var state = SyncState()
        state.hasGoodAccountStatus = true
        let createSubscription = SyncWork.setup(SetupOperation(step: .subscription))
        let createZone = SyncWork.setup(SetupOperation(step: .zone))

        state.enqueue(createSubscription)
        state.enqueue(createZone)

        XCTAssertEqual(state.currentWork?.id, createZone.id)

        state.apply(.succeeded(.setup(true)), to: createZone)

        XCTAssertEqual(state.currentWork?.id, createSubscription.id)
    }

    func testModifiesQueuedBeforeSetupFinishesRunBeforeFetches() {
        var state = SyncState()
        let firstModify = makeModify()

        state.enqueue(firstModify)
        state.enqueue(makeModify())
        state.enqueue(makeFetch())
        state.enqueue(makeModify())
        finishSetup(of: &state)

        XCTAssertEqual(state.operationMode, .modify)
        XCTAssertEqual(state.currentWork?.id, firstModify.id)
    }

    func testFetchesRunWhenThereAreNoModifies() {
        var state = SyncState()
        let fetch = makeFetch()

        state.enqueue(fetch)
        finishSetup(of: &state)

        XCTAssertEqual(state.operationMode, .fetch)
        XCTAssertEqual(state.currentWork?.id, fetch.id)
    }

    func testFetchesRunAfterTheLastModifyFinishes() {
        var state = makeRunningState()
        let fetch = makeFetch()
        let modify = makeModify()

        state.enqueue(modify)
        state.enqueue(fetch)

        XCTAssertEqual(state.currentWork?.id, modify.id)

        state.apply(.succeeded(.modify(ModifyOperation.Response(savedRecords: [], deletedRecordIDs: []))), to: modify)

        XCTAssertEqual(state.operationMode, .fetch)
        XCTAssertEqual(state.currentWork?.id, fetch.id)
    }

    func testModifyQueuedDuringAFetchWaitsForQueuedFetches() {
        var state = makeRunningState()
        let fetch = makeFetch()

        state.enqueue(fetch)
        state.enqueue(makeModify())

        XCTAssertEqual(state.currentWork?.id, fetch.id)
    }

    func testOperationModeClearsWhenTheQueuesEmpty() {
        var state = makeRunningState()
        let modify = makeModify()

        state.enqueue(modify)
        state.apply(.succeeded(.modify(ModifyOperation.Response(savedRecords: [], deletedRecordIDs: []))), to: modify)

        XCTAssertNil(state.operationMode)
        XCTAssertNil(state.currentWork)
        XCTAssertFalse(state.hasWorkQueued)
    }

    // MARK: How an attempt ends

    func testFetchWithMoreToComePutsTheNextPageFirst() {
        var state = makeRunningState()
        let firstFetch = makeFetch()
        let laterFetch = makeFetch()

        state.enqueue(firstFetch)
        state.enqueue(laterFetch)
        state.apply(
            .succeeded(.fetch(FetchOperation.Response(changeToken: nil, changedRecords: [], deletedRecordIDs: [], hasMore: true))),
            to: firstFetch
        )

        XCTAssertEqual(state.fetchQueue.count, 2)
        XCTAssertNotEqual(state.fetchQueue.first?.id, laterFetch.id)
        XCTAssertEqual(state.fetchQueue.last?.id, laterFetch.id)
    }

    func testSuccessClearsTheRetryCount() {
        var state = makeRunningState()
        let modify = makeModify()

        state.enqueue(modify)
        state.apply(.retryScheduled(TestError()), to: modify)

        XCTAssertEqual(state.retryCount, 1)
        XCTAssertNotNil(state.lastRetryError)

        state.apply(.succeeded(.modify(ModifyOperation.Response(savedRecords: [], deletedRecordIDs: []))), to: modify)

        XCTAssertEqual(state.retryCount, 0)
        XCTAssertNil(state.lastRetryError)
    }

    func testRetriedWorkKeepsItsPlaceAndCountsTheRetry() {
        var state = makeRunningState()
        let first = makeModify()
        let second = makeModify()

        state.enqueue(first)
        state.enqueue(second)
        state.apply(.retrying(first), to: first)

        XCTAssertEqual(state.modifyQueue.map(\.id), [first.id, second.id])
        XCTAssertEqual(state.modifyQueue.first?.retryCount, 1)
    }

    func testReplacementsTakeTheFailedWorksPlaceInOrder() {
        var state = makeRunningState()
        let first = makeModify()
        let second = makeModify()
        let replacements = [makeModifyOperation(), makeModifyOperation()]

        state.enqueue(first)
        state.enqueue(second)
        state.apply(.replaced(replacements), to: first)

        XCTAssertEqual(state.modifyQueue.map(\.id), replacements.map(\.id) + [second.id])
    }

    func testMissingSetupIsRedoneAheadOfTheWorkThatFoundItMissing() {
        var state = makeRunningState()
        let first = makeModify()
        let second = makeModify()
        let createZoneOperation = SetupOperation(step: .zone)

        state.enqueue(first)
        state.enqueue(second)
        state.apply(.setupMissing(createZoneOperation), to: first)

        XCTAssertEqual(state.operationMode, .setup(.zone))
        XCTAssertEqual(state.currentWork?.id, createZoneOperation.id)
        XCTAssertEqual(state.modifyQueue.map(\.id), [first.id, second.id])
        XCTAssertEqual(state.modifyQueue.first?.retryCount, 1)

        state.apply(.succeeded(.setup(true)), to: .setup(createZoneOperation))

        XCTAssertEqual(state.currentWork?.id, first.id)
    }

    func testMissingSetupIsNotQueuedTwice() {
        var state = makeRunningState()
        let first = makeModify()

        state.enqueue(first)
        state.apply(.setupMissing(SetupOperation(step: .zone)), to: first)
        state.apply(.setupMissing(SetupOperation(step: .zone)), to: first)

        XCTAssertEqual(state.setupQueue.count, 1)
    }

    func testOutcomeForWorkThatIsNoLongerQueuedChangesNothing() {
        var state = makeRunningState()
        let queued = makeModify()
        let forgotten = makeModify()

        state.enqueue(queued)

        XCTAssertFalse(state.apply(.succeeded(.modify(ModifyOperation.Response(savedRecords: [], deletedRecordIDs: []))), to: forgotten))
        XCTAssertFalse(state.apply(.replaced([makeModifyOperation()]), to: forgotten))
        XCTAssertEqual(state.modifyQueue.map(\.id), [queued.id])
    }

    // MARK: Queue bookkeeping

    func testPopWork() {
        var state = SyncState()
        let work = makeFetch()

        state.enqueue(work)
        state.popWork(work: work)

        XCTAssertEqual(state.fetchQueue.count, 0)
    }

    func testPopRetriedWork() {
        var state = SyncState()
        let work = makeFetch().retried

        state.enqueue(work)
        state.popWork(work: work)

        XCTAssertEqual(state.fetchQueue.count, 0)
    }

    func testFetchFromAChangeTokenThatIsAlreadyQueuedIsRecognised() {
        var state = SyncState()

        XCTAssertFalse(state.hasQueuedFetch(from: nil))

        state.enqueue(makeFetch())

        XCTAssertTrue(state.hasQueuedFetch(from: nil))
    }

    // MARK: Retry policy

    func testRetryPolicyBacksOffQuadraticallyAndGivesUpAfterFiveRetries() {
        XCTAssertEqual(
            (0 ..< 5).map { RetryPolicy.decision(retryCount: $0, suggestedInterval: nil) },
            [.wait(0), .wait(1), .wait(4), .wait(9), .wait(16)]
        )
        XCTAssertEqual(RetryPolicy.decision(retryCount: 5, suggestedInterval: nil), .giveUp)
    }

    func testRetryPolicyPrefersTheWaitTheServerAskedFor() {
        XCTAssertEqual(RetryPolicy.decision(retryCount: 3, suggestedInterval: 315), .wait(315))
        XCTAssertEqual(RetryPolicy.decision(retryCount: 5, suggestedInterval: 315), .giveUp)
    }

    // MARK: Helpers

    private func makeModifyOperation() -> ModifyOperation {
        ModifyOperation(records: [], recordIDsToDelete: [], checkpointID: nil, userInfo: nil)
    }

    private func makeModify() -> SyncWork {
        .modify(makeModifyOperation())
    }

    private func makeFetch() -> SyncWork {
        .fetch(FetchOperation(changeToken: nil))
    }

    /// A state in which the account is available and the zone and subscription exist.
    private func makeRunningState() -> SyncState {
        var state = SyncState()

        finishSetup(of: &state)

        return state
    }

    private func finishSetup(of state: inout SyncState) {
        let createZone = SyncWork.setup(SetupOperation(step: .zone))
        let createSubscription = SyncWork.setup(SetupOperation(step: .subscription))

        state.hasGoodAccountStatus = true
        state.enqueue(createZone)
        state.enqueue(createSubscription)
        state.apply(.succeeded(.setup(true)), to: createZone)
        state.apply(.succeeded(.setup(true)), to: createSubscription)
    }
}
