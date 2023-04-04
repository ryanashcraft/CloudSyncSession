import CloudKit
@testable import CloudSyncSession
import XCTest

private var testZoneID = CKRecordZone.ID(
    zoneName: "test",
    ownerName: CKCurrentUserDefaultName
)

final class SyncStateTests: XCTestCase {
    func testIgnoresWorkIfUnknownAccountStatus() {
        var state = SyncState()

        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: [], checkpointID: nil, userInfo: nil))))

        XCTAssertNil(state.currentWork)
    }

    func testIgnoresWorkIfUnknownZoneStatus() {
        var state = SyncState()

        state = state.reduce(event: .accountStatusChanged(.available))
        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: [], checkpointID: nil, userInfo: nil))))

        XCTAssertNil(state.currentWork)
    }

    func testStartsWorkIfKnownAccountStatusAndZoneCreated() {
        var state = SyncState()

        state = state.reduce(event: .accountStatusChanged(.available))
        let createZoneWork = SyncWork.createZone(CreateZoneOperation(zoneID: testZoneID))
        state = state.reduce(event: .workSuccess(createZoneWork, .createZone(true)))
        let createSubscriptionWork = SyncWork.createSubscription(CreateSubscriptionOperation(zoneID: testZoneID))
        state = state.reduce(event: .workSuccess(createSubscriptionWork, .createSubscription(true)))
        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: [], checkpointID: nil, userInfo: nil))))

        XCTAssertNotNil(state.currentWork)
    }

    func testStartsModificiationsBeforeFetches() {
        var state = SyncState()

        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: [], checkpointID: nil, userInfo: nil))))
        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: [], checkpointID: nil, userInfo: nil))))
        state = state.reduce(event: .doWork(.fetch(FetchOperation(changeToken: nil))))
        state = state.reduce(event: .doWork(.modify(ModifyOperation(records: [], recordIDsToDelete: [], checkpointID: nil, userInfo: nil))))

        state = state.reduce(event: .accountStatusChanged(.available))
        let createZoneWork = SyncWork.createZone(CreateZoneOperation(zoneID: testZoneID))
        state = state.reduce(event: .workSuccess(createZoneWork, .createZone(true)))
        let createSubscriptionWork = SyncWork.createSubscription(CreateSubscriptionOperation(zoneID: testZoneID))
        state = state.reduce(event: .workSuccess(createSubscriptionWork, .createSubscription(true)))

        XCTAssertEqual(state.operationMode, SyncState.OperationMode.modify)

        switch state.currentWork {
        case .fetch, .createZone, .createSubscription, nil:
            XCTFail()
        case .modify:
            break
        }
    }

    func testStartsFetchingIfNoModifications() {
        var state = SyncState()

        state = state.reduce(event: .doWork(.fetch(FetchOperation(changeToken: nil))))

        state = state.reduce(event: .accountStatusChanged(.available))
        let createZoneWork = SyncWork.createZone(CreateZoneOperation(zoneID: testZoneID))
        state = state.reduce(event: .workSuccess(createZoneWork, .createZone(true)))
        let createSubscriptionWork = SyncWork.createSubscription(CreateSubscriptionOperation(zoneID: testZoneID))
        state = state.reduce(event: .workSuccess(createSubscriptionWork, .createSubscription(true)))

        XCTAssertEqual(state.operationMode, SyncState.OperationMode.fetch)

        switch state.currentWork {
        case .modify, .createZone, .createSubscription, nil:
            XCTFail()
        case .fetch:
            break
        }
    }

    func testOperationModeResetsAfterAllWorkSuccess() {
        var state = SyncState()

        let modifyWork = SyncWork.modify(ModifyOperation(records: [], recordIDsToDelete: [], checkpointID: nil, userInfo: nil))
        state = state.reduce(event: .doWork(modifyWork))
        state = state.reduce(event: .workSuccess(modifyWork, .modify(ModifyOperation.Response(savedRecords: [], deletedRecordIDs: []))))

        state = state.reduce(event: .accountStatusChanged(.available))
        let createZoneWork = SyncWork.createZone(CreateZoneOperation(zoneID: testZoneID))
        state = state.reduce(event: .workSuccess(createZoneWork, .createZone(true)))

        XCTAssertNil(state.operationMode)
        XCTAssertNil(state.currentWork)
    }

    func testStartsFetchingAfterModifications() {
        var state = SyncState()

        state = state.reduce(event: .doWork(.fetch(FetchOperation(changeToken: nil))))

        let modifyWork = SyncWork.modify(ModifyOperation(records: [], recordIDsToDelete: [], checkpointID: nil, userInfo: nil))
        state = state.reduce(event: .doWork(modifyWork))
        state = state.reduce(event: .workSuccess(modifyWork, .modify(ModifyOperation.Response(savedRecords: [], deletedRecordIDs: []))))

        state = state.reduce(event: .accountStatusChanged(.available))
        let createZoneWork = SyncWork.createZone(CreateZoneOperation(zoneID: testZoneID))
        state = state.reduce(event: .workSuccess(createZoneWork, .createZone(true)))
        let createSubscriptionWork = SyncWork.createSubscription(CreateSubscriptionOperation(zoneID: testZoneID))
        state = state.reduce(event: .workSuccess(createSubscriptionWork, .createSubscription(true)))

        XCTAssertEqual(state.operationMode, SyncState.OperationMode.fetch)

        switch state.currentWork {
        case .modify, .createZone, .createSubscription, nil:
            XCTFail()
        case .fetch:
            break
        }
    }

    func testPopWork() {
        var state = SyncState()

        let work = SyncWork.fetch(FetchOperation(changeToken: nil))
        state = state.reduce(event: .doWork(work))
        state.popWork(work: work)

        XCTAssertEqual(state.fetchQueue.count, 0)
    }

    func testPopRetriedWork() {
        var state = SyncState()

        var work = SyncWork.fetch(FetchOperation(changeToken: nil))
        work = work.retried
        state = state.reduce(event: .doWork(work))
        state.popWork(work: work)

        XCTAssertEqual(state.fetchQueue.count, 0)
    }
}
