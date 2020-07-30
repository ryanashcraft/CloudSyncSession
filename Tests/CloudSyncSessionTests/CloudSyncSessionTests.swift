import Combine
import XCTest
@testable import CloudSyncSession

class SuccessfulMockOperationHandler: OperationHandler {
    func handle(createZoneOperation: CreateZoneOperation, dispatch: @escaping (SyncEvent) -> Void) {

    }

    func handle(fetchOperation: FetchOperation, dispatch: @escaping (SyncEvent) -> Void) {

    }

    func handle(modifyOperation: ModifyOperation, dispatch: @escaping (SyncEvent) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            dispatch(.modifyCompleted(modifyOperation.records, []))
        }
    }
}

class FailingMockOperationHandler: OperationHandler {
    func handle(createZoneOperation: CreateZoneOperation, dispatch: @escaping (SyncEvent) -> Void) {

    }

    func handle(fetchOperation: FetchOperation, dispatch: @escaping (SyncEvent) -> Void) {

    }

    func handle(modifyOperation: ModifyOperation, dispatch: @escaping (SyncEvent) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            dispatch(.modifyFailure(CKError(.notAuthenticated), modifyOperation))
        }
    }
}

class PartialFailureMockOperationHandler: OperationHandler {
    func handle(createZoneOperation: CreateZoneOperation, dispatch: @escaping (SyncEvent) -> Void) {

    }

    func handle(fetchOperation: FetchOperation, dispatch: @escaping (SyncEvent) -> Void) {
        
    }

    func handle(modifyOperation: ModifyOperation, dispatch: @escaping (SyncEvent) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            dispatch(.modifyFailure(CKError(.partialFailure), modifyOperation))
        }
    }
}

private var testIdentifier = "8B14FD76-EA56-49B0-A184-6C01828BA20A"

private var testRecord = CKRecord(
    recordType: "Test",
    recordID: CKRecord.ID(recordName: testIdentifier)
)

final class CloudSyncSessionTests: XCTestCase {
    func testUnhaltsAfterAccountAvailableAndZoneCreated() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")
        let mockOperationHandler = SuccessfulMockOperationHandler()
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler
        )

        session.dispatch(event: .accountStatusChanged(.available))
        session.dispatch(event: .createZoneCompleted)

        session.$state
            .sink { newState in
                if newState.isRunning {
                    expectation.fulfill()
                }
            }
            .store(in: &tasks)

        wait(for: [expectation], timeout: 1)
    }

    func testModifySuccess() {
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = SuccessfulMockOperationHandler()
        let session = CloudSyncSession(operationHandler: mockOperationHandler)
        session.state = SyncState(hasGoodAccountStatus: true, hasCreatedZone: true)

        session.onRecordsModified = { records in
            XCTAssertEqual(records.count, 1)

            expectation.fulfill()
        }

        session.dispatch(event: .modify([testRecord]))

        wait(for: [expectation], timeout: 1)
    }

    func testModifyFailure() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = FailingMockOperationHandler()
        let session = CloudSyncSession(operationHandler: mockOperationHandler)
        session.state = SyncState(hasGoodAccountStatus: true, hasCreatedZone: true)

        session.onRecordsModified = { records in
            XCTFail()
        }

        session.$state
            .sink { newState in
                if !newState.isRunning {
                    expectation.fulfill()
                }
            }
            .store(in: &tasks)

        session.dispatch(event: .modify([testRecord]))

        wait(for: [expectation], timeout: 1)
    }

    func testHaltedIgnoresModifyEvents() {
        let expectation = self.expectation(description: "work")
        expectation.isInverted = true

        let mockOperationHandler = SuccessfulMockOperationHandler()
        let session = CloudSyncSession(operationHandler: mockOperationHandler)
        session.state = SyncState(hasGoodAccountStatus: true, hasHalted: true, hasCreatedZone: true)

        session.onRecordsModified = { records in
            expectation.fulfill()
        }

        session.dispatch(event: .modify([testRecord]))

        wait(for: [expectation], timeout: 1)
    }

    func testDoesNotUnhaltAfterFailure() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")
        expectation.assertForOverFulfill = false

        let mockOperationHandler = FailingMockOperationHandler()
        let session = CloudSyncSession(operationHandler: mockOperationHandler)
        session.state = SyncState(hasGoodAccountStatus: true, hasCreatedZone: true)

        session.$state
            .receive(on: DispatchQueue.main)
            .sink { newState in
                if newState.hasHalted {
                    session.dispatch(event: .accountStatusChanged(.available))
                    XCTAssertFalse(session.state.isRunning)
                    expectation.fulfill()
                }
            }
            .store(in: &tasks)

        session.dispatch(event: .modify([testRecord]))

        wait(for: [expectation], timeout: 1)
    }

    func testResumesWorkAfterUnhalting() {
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = SuccessfulMockOperationHandler()
        let session = CloudSyncSession(operationHandler: mockOperationHandler)
        session.state = SyncState(hasGoodAccountStatus: false, hasCreatedZone: true)

        session.onRecordsModified = { records in
            XCTAssertEqual(records.count, 1)

            expectation.fulfill()
        }

        session.dispatch(event: .modify([testRecord]))
        session.dispatch(event: .accountStatusChanged(.available))

        wait(for: [expectation], timeout: 1)
    }

    func testHaltAfterPartialFailureWithoutRecovery() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = PartialFailureMockOperationHandler()
        let session = CloudSyncSession(operationHandler: mockOperationHandler)
        session.state = SyncState(hasGoodAccountStatus: true, hasCreatedZone: true)

        // Won't recover because no conflict handler set up

        session.$state
            .receive(on: DispatchQueue.main)
            .sink { newState in
                if newState.hasHalted {
                    expectation.fulfill()
                }
            }
            .store(in: &tasks)

        session.dispatch(event: .modify([testRecord]))

        wait(for: [expectation], timeout: 1)
    }
}
