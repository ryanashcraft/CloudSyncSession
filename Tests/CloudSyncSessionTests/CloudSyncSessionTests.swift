import Combine
import XCTest
@testable import CloudSyncSession

class SuccessfulMockOperationHandler: OperationHandler {
    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<[CKRecord], Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            completion(.success(modifyOperation.records))
        }
    }
}

class FailingMockOperationHandler: OperationHandler {
    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<[CKRecord], Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            completion(.failure(CKError(.notAuthenticated)))
        }
    }
}

private var testIdentifier = "8B14FD76-EA56-49B0-A184-6C01828BA20A"

private var testRecord = CKRecord(
    recordType: "Test",
    recordID: CKRecord.ID(recordName: testIdentifier)
)

final class CloudSyncSessionTests: XCTestCase {
    func testUnhaltsAfterAccountAvailable() {
        let mockOperationHandler = SuccessfulMockOperationHandler()
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler
        )

        session.dispatch(event: .accountStatusChanged(.available))

        XCTAssertTrue(session.state.isRunning)
    }

    func testModifySuccess() {
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = SuccessfulMockOperationHandler()
        let initialState = SyncState(hasGoodAccountStatus: true)
        let session = CloudSyncSession(
            initialState: initialState,
            operationHandler: mockOperationHandler
        )

        session.onRecordsModified = { records in
            XCTAssertEqual(records.count, 1)
            XCTAssertNil(session.state.currentWork)

            expectation.fulfill()
        }

        session.dispatch(event: .modify([testRecord]))

        wait(for: [expectation], timeout: 1)
    }

    func testModifyFailure() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = FailingMockOperationHandler()
        let initialState = SyncState(hasGoodAccountStatus: true)
        let session = CloudSyncSession(
            initialState: initialState,
            operationHandler: mockOperationHandler
        )

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
        let initialState = SyncState(hasGoodAccountStatus: true, hasHalted: true)
        let session = CloudSyncSession(
            initialState: initialState,
            operationHandler: mockOperationHandler
        )

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
        let initialState = SyncState(hasGoodAccountStatus: true)
        let session = CloudSyncSession(
            initialState: initialState,
            operationHandler: mockOperationHandler
        )

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
}