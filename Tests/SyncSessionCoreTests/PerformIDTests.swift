@testable import SyncSessionCore
import XCTest

/// The ID a `perform` call puts on its operation has to stay on whatever takes the operation's
/// place in the queue, or the session loses track of what the call is waiting for.
final class PerformIDTests: XCTestCase {
    private let performID = UUID()

    private func ownedModify(saves: Int, deletes: Int = 0) -> ModifyOperation {
        var operation = makeModify(saves: saves, deletes: deletes)

        operation.performID = performID

        return operation
    }

    func testEveryPieceOfASizeSplitCarriesIt() {
        let pieces = ownedModify(saves: TestBackend.maxItemsPerModify + 1, deletes: 1).split

        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces.map(\.performID), [performID, performID, performID])
    }

    func testBothHalvesCarryIt() {
        XCTAssertEqual(ownedModify(saves: 4).splitInHalf?.map(\.performID), [performID, performID])
        XCTAssertEqual(ownedModify(saves: 1, deletes: 1).splitInHalf?.map(\.performID), [performID, performID])
    }

    func testWorkThatReplacesItInTheQueueCarriesItWhateverTheReplacementHad() {
        var state = SyncState()
        let operation = ownedModify(saves: 2)

        state.enqueue(.modify(operation))
        state.apply(.replaced([makeModify(), makeModify()]), to: .modify(operation))

        XCTAssertEqual(state.modifyQueue.map(\.performID), [performID, performID])
    }

    func testARetryBuiltByTheBackendCarriesIt() {
        var state = SyncState()
        var operation = FetchOperation(changeToken: 1)

        operation.performID = performID
        state.enqueue(.fetch(operation))
        state.apply(.retrying(.fetch(FetchOperation(changeToken: 9))), to: .fetch(operation))

        XCTAssertEqual(state.fetchQueue.map(\.performID), [performID])
        XCTAssertEqual(state.fetchQueue.map(\.changeToken), [9])
    }

    func testTheFollowUpOfAFetchDoesNotCarryIt() {
        var state = SyncState()
        var operation = FetchOperation(changeToken: 1)

        operation.performID = performID
        state.enqueue(.fetch(operation))
        state.apply(
            .succeeded(.fetch(.init(changeToken: 2, changedRecords: [], deletedRecordIDs: [], hasMore: true))),
            to: .fetch(operation)
        )

        XCTAssertEqual(state.fetchQueue.count, 1)
        XCTAssertNil(state.fetchQueue.first?.performID)
        XCTAssertFalse(state.hasWork(performID: performID))
    }

    func testWithdrawingTakesOutItsWorkAndNothingElse() {
        var state = SyncState()
        let pieces = ownedModify(saves: TestBackend.maxItemsPerModify + 1).split
        let other = makeModify()
        var fetch = FetchOperation(changeToken: 1)

        fetch.performID = performID

        for piece in pieces {
            state.enqueue(.modify(piece))
        }

        state.enqueue(.modify(other))
        state.enqueue(.fetch(fetch))

        XCTAssertTrue(state.hasWork(performID: performID))
        XCTAssertEqual(state.queuedPerformIDs, [performID])

        state.withdrawWork(performID: performID, except: pieces[0].id)

        XCTAssertEqual(state.modifyQueue.map(\.id), [pieces[0].id, other.id])
        XCTAssertTrue(state.fetchQueue.isEmpty)

        state.withdrawWork(performID: performID, except: nil)

        XCTAssertEqual(state.modifyQueue.map(\.id), [other.id])
        XCTAssertFalse(state.hasWork(performID: performID))
    }
}
