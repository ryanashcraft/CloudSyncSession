@testable import SyncSessionCore
import XCTest

final class SessionStreamsTests: XCTestCase {
    // MARK: events

    func testEventsAreDeliveredInOrderFromWhenTheStreamIsMade() async {
        let test = TestSession()

        test.session.fetch(FetchOperation(changeToken: 1))

        var events = test.session.events.makeAsyncIterator()

        test.session.modify(makeModify())
        test.session.stop()

        guard case .doWork(.modify) = await events.next() else {
            return XCTFail("Expected the modify queued after the stream was made, with nothing replayed before it")
        }

        guard case .halt = await events.next() else {
            return XCTFail("Expected the halt second")
        }
    }

    func testEveryStreamOfOneKindGetsEveryElement() async {
        let test = TestSession()
        var first = test.session.events.makeAsyncIterator()
        var second = test.session.events.makeAsyncIterator()

        test.session.stop()
        test.session.start()

        guard case .halt = await first.next(), case .halt = await second.next() else {
            return XCTFail("Expected both streams to see the halt")
        }

        guard case .start = await first.next(), case .start = await second.next() else {
            return XCTFail("Expected both streams to see the start")
        }
    }

    // MARK: Completions

    func testFetchCompletionsReportAPageAndTheFollowUpTheSessionFetches() async {
        let test = TestSession()
        var completions = test.session.fetchCompletions.makeAsyncIterator()

        await test.reply(.succeedWithMore, .succeed)
        test.startRunning()
        test.session.fetch(FetchOperation(changeToken: 1))

        let first = await completions.next()
        let second = await completions.next()

        XCTAssertEqual(first?.0.changeToken, 1)
        XCTAssertEqual(first?.1.hasMore, true)
        XCTAssertEqual(second?.0.changeToken, 2)
        XCTAssertEqual(second?.1.hasMore, false)
    }

    func testModifyCompletionsReportEachPieceOfASplitOperation() async {
        let test = TestSession()
        var completions = test.session.modifyCompletions.makeAsyncIterator()

        test.startRunning()
        test.session.modify(makeModify(saves: TestBackend.maxItemsPerModify + 1))

        let first = await completions.next()
        let second = await completions.next()

        XCTAssertEqual(first?.1.savedRecords.count, TestBackend.maxItemsPerModify)
        XCTAssertNil(first?.0.checkpointID)
        XCTAssertEqual(second?.1.savedRecords.count, 1)
        XCTAssertNotNil(second?.0.checkpointID)
    }

    func testACompletionFromBeforeTheStreamWasMadeIsNotReplayed() async {
        let test = TestSession()
        var earlier = test.session.modifyCompletions.makeAsyncIterator()

        test.startRunning()
        test.session.modify(makeModify(saves: 1))
        _ = await earlier.next()

        var later = test.session.modifyCompletions.makeAsyncIterator()

        test.session.modify(makeModify(saves: 2))

        let completion = await later.next()

        XCTAssertEqual(completion?.1.savedRecords.count, 2)
    }

    // MARK: halts

    func testHaltsStartWithNilAndFollowEveryHaltAndResume() async {
        let test = TestSession()
        var halts = test.session.halts.makeAsyncIterator()

        guard case .some(nil) = await halts.next() else {
            return XCTFail("Expected nil first: the session is not halted")
        }

        await test.reply(.fail(.halt))
        test.startRunning()
        test.session.modify(makeModify())

        let failure = await halts.next()

        XCTAssertEqual((failure ?? nil) as? ScriptedFailure, .halt)

        test.session.start()

        guard case .some(nil) = await halts.next() else {
            return XCTFail("Expected nil after start() resumed the session")
        }

        test.session.stop()

        let stop = await halts.next()

        XCTAssertTrue((stop ?? nil) is TestBackend.StopError)

        test.session.reset()

        guard case .some(nil) = await halts.next() else {
            return XCTFail("Expected nil after reset() cleared the halt")
        }
    }

    func testHaltsMadeWhileHaltedStartWithTheError() async {
        let test = TestSession()

        test.session.stop()

        var halts = test.session.halts.makeAsyncIterator()
        let current = await halts.next()

        XCTAssertTrue((current ?? nil) is TestBackend.StopError)
    }

    func testStartOnASessionThatIsNotHaltedSendsNoHalt() async {
        let test = TestSession()
        var halts = test.session.halts.makeAsyncIterator()

        _ = await halts.next()

        test.session.start()
        test.session.stop()

        let next = await halts.next()

        XCTAssertTrue((next ?? nil) is TestBackend.StopError, "The start should have sent nothing, so the stop comes next")
    }

    // MARK: states

    func testStatesStartWithTheCurrentStateAndKeepOnlyTheNewestUnreadOne() async {
        let test = TestSession()

        test.session.modify(makeModify())

        var states = test.session.states.makeAsyncIterator()
        let current = await states.next()

        XCTAssertEqual(current?.modifyQueue.count, 1)

        for _ in 0 ..< 100 {
            test.session.modify(makeModify())
        }

        let newest = await states.next()

        XCTAssertEqual(newest?.modifyQueue.count, 101)

        test.session.modify(makeModify())

        let next = await states.next()

        XCTAssertEqual(next?.modifyQueue.count, 102, "The 99 states in between should have been dropped, not queued")
    }

    func testStatesFollowTheSessionOutOfAHalt() async {
        let test = TestSession()

        test.session.stop()

        let states = test.session.states

        test.session.start()

        for await state in states where !state.isHalted {
            break
        }
    }

    // MARK: Ending

    func testStreamsEndWhenTheSessionIsReleased() async {
        var test: TestSession? = TestSession()
        let events = test!.session.events
        let states = test!.session.states
        let halts = test!.session.halts
        let fetchCompletions = test!.session.fetchCompletions
        let modifyCompletions = test!.session.modifyCompletions

        test = nil

        for await _ in events {}
        for await _ in states {}
        for await _ in halts {}
        for await _ in fetchCompletions {}
        for await _ in modifyCompletions {}
    }

    func testAStreamThatIsDroppedIsForgotten() async {
        let test = TestSession()

        do {
            _ = test.session.states
            _ = test.session.fetchCompletions
        }

        // Removal hops to another queue, and a later state change is the only way to see it from
        // outside, so wait on the session's own bookkeeping.
        var states = test.session.states.makeAsyncIterator()

        while test.session.observerCount > 2 {
            test.session.modify(makeModify())
            _ = await states.next()
            await Task.yield()
        }
    }
}
