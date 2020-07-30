import XCTest
@testable import CloudSyncSession

private var testZoneID = CKRecordZone.ID(
    zoneName: "test",
    ownerName: CKCurrentUserDefaultName
)

final class SyncStateTests: XCTestCase {
    func testIgnoresWorkIfUnknownAccountStatus() {
        var state = SyncState()

        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: []))))

        XCTAssertNil(state.currentWork)
    }

    func testIgnoresWorkIfUnknownZoneStatus() {
        var state = SyncState()

        state = state.reduce(event: .accountStatusChanged(.available))
        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: []))))

        XCTAssertNil(state.currentWork)
    }

    func testStartsWorkIfKnownAccountStatusAndZoneCreated() {
        var state = SyncState()

        state = state.reduce(event: .accountStatusChanged(.available))
        state = state.reduce(event: .workSuccess(.createZone(true)))
        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: []))))

        XCTAssertNotNil(state.currentWork)
    }

    func testStartsModificiationsBeforeFetches() {
        var state = SyncState()

        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: []))))
        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: []))))
        state = state.reduce(event: .doWork(.fetch(FetchOperation(changeToken: nil))))
        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: []))))

        state = state.reduce(event: .accountStatusChanged(.available))
        state = state.reduce(event: .workSuccess(.createZone(true)))

        XCTAssertEqual(state.operationMode, SyncState.OperationMode.modify)

        switch state.currentWork {
        case .fetch, .createZone, nil:
            XCTFail()
        case .modify:
            break
        }
    }

    func testStartsFetchingIfNoModifications() {
        var state = SyncState()

        state = state.reduce(event: .doWork(.fetch(FetchOperation(changeToken: nil))))

        state = state.reduce(event: .accountStatusChanged(.available))
        state = state.reduce(event: .workSuccess(.createZone(true)))

        XCTAssertEqual(state.operationMode, SyncState.OperationMode.fetch)

        switch state.currentWork {
        case .modify, .createZone, nil:
            XCTFail()
        case .fetch:
            break
        }
    }

    func testOperationModeResetsAfterAllWorkSuccess() {
        var state = SyncState()

        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: []))))
        state = state.reduce(event: .workSuccess(.modify(ModifyOperation.Response(savedRecords: [], deletedRecordIDs: []))))

        state = state.reduce(event: .accountStatusChanged(.available))
        state = state.reduce(event: .workSuccess(.createZone(true)))

        XCTAssertNil(state.operationMode)
        XCTAssertNil(state.currentWork)
    }

    func testStartsFetchingAfterModifications() {
        var state = SyncState()

        state = state.reduce(event: .doWork(.fetch(FetchOperation(changeToken: nil))))

        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: []))))
        state = state.reduce(event: .workSuccess(.modify(ModifyOperation.Response(savedRecords: [], deletedRecordIDs: []))))

        state = state.reduce(event: .accountStatusChanged(.available))
        state = state.reduce(event: .workSuccess(.createZone(true)))

        XCTAssertEqual(state.operationMode, SyncState.OperationMode.fetch)

        switch state.currentWork {
        case .modify, .createZone, nil:
            XCTFail()
        case .fetch:
            break
        }
    }
}
