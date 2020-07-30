import Combine
import XCTest
@testable import CloudSyncSession

class SuccessfulMockOperationHandler: OperationHandler {
    func handle(createZoneOperation: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void) {

    }

    func handle(fetchOperation: FetchOperation, completion: @escaping (Result<FetchOperation.Response, Error>) -> Void) {

    }

    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            completion(.success(ModifyOperation.Response(savedRecords: modifyOperation.records, deletedRecordIDs: [])))
        }
    }
}

class FailingMockOperationHandler: OperationHandler {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func handle(createZoneOperation: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void) {

    }

    func handle(fetchOperation: FetchOperation, completion: @escaping (Result<FetchOperation.Response, Error>) -> Void) {

    }

    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            completion(.failure(self.error))
        }
    }
}

class FailOnceMockOperationHandler: OperationHandler {
    let error: Error

    private var operationCount = 0

    init(error: Error) {
        self.error = error
    }

    func handle(createZoneOperation: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void) {

    }

    func handle(fetchOperation: FetchOperation, completion: @escaping (Result<FetchOperation.Response, Error>) -> Void) {

    }

    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            self.operationCount += 1

            if self.operationCount > 1 {
                completion(.success(ModifyOperation.Response(savedRecords: modifyOperation.records, deletedRecordIDs: [])))
            } else {
                completion(.failure(self.error))
            }
        }
    }
}

class PartialFailureMockOperationHandler: OperationHandler {
    func handle(createZoneOperation: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void) {

    }

    func handle(fetchOperation: FetchOperation, completion: @escaping (Result<FetchOperation.Response, Error>) -> Void) {
        
    }

    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            completion(.failure(CKError(.partialFailure)))
        }
    }
}

private var testIdentifier = "8B14FD76-EA56-49B0-A184-6C01828BA20A"

private var testZoneID = CKRecordZone.ID(
    zoneName: "test",
    ownerName: CKCurrentUserDefaultName
)

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
            operationHandler: mockOperationHandler,
            zoneIdentifier: testZoneID
        )

        session.dispatch(event: .accountStatusChanged(.available))
        let createZoneWork = SyncWork.createZone(CreateZoneOperation(zoneIdentifier: testZoneID))
        session.dispatch(event: .workSuccess(.createZone(true), createZoneWork))

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
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneIdentifier: testZoneID
        )
        session.state = SyncState(hasGoodAccountStatus: true, hasCreatedZone: true)

        session.onRecordsModified = { records, _ in
            XCTAssertEqual(records.count, 1)

            expectation.fulfill()
        }

        let operation = ModifyOperation(records: [testRecord], recordIDsToDelete: [])
        session.dispatch(event: .doWork(.modify(operation)))

        wait(for: [expectation], timeout: 1)
    }

    func testModifyFailure() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = FailingMockOperationHandler(error: CKError(.notAuthenticated))
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneIdentifier: testZoneID
        )
        session.state = SyncState(hasGoodAccountStatus: true, hasCreatedZone: true)

        session.onRecordsModified = { records, _ in
            XCTFail()
        }

        session.$state
            .sink { newState in
                if !newState.isRunning {
                    expectation.fulfill()
                }
            }
            .store(in: &tasks)

        let operation = ModifyOperation(records: [testRecord], recordIDsToDelete: [])
        session.dispatch(event: .doWork(.modify(operation)))

        wait(for: [expectation], timeout: 1)
    }

    func testHaltedIgnoresModifyEvents() {
        let expectation = self.expectation(description: "work")
        expectation.isInverted = true

        let mockOperationHandler = SuccessfulMockOperationHandler()
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneIdentifier: testZoneID
        )
        session.state = SyncState(hasGoodAccountStatus: true, hasCreatedZone: true, hasHalted: true)

        session.onRecordsModified = { records, _ in
            expectation.fulfill()
        }

        let operation = ModifyOperation(records: [testRecord], recordIDsToDelete: [])
        session.dispatch(event: .doWork(.modify(operation)))

        wait(for: [expectation], timeout: 1)
    }

    func testDoesNotUnhaltAfterFailure() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")
        expectation.assertForOverFulfill = false

        let mockOperationHandler = FailingMockOperationHandler(error: CKError(.notAuthenticated))
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneIdentifier: testZoneID
        )
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

        let operation = ModifyOperation(records: [testRecord], recordIDsToDelete: [])
        session.dispatch(event: .doWork(.modify(operation)))

        wait(for: [expectation], timeout: 1)
    }

    func testResumesWorkAfterUnhalting() {
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = SuccessfulMockOperationHandler()
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneIdentifier: testZoneID
        )
        session.state = SyncState(hasGoodAccountStatus: false, hasCreatedZone: true)

        session.onRecordsModified = { records, _ in
            XCTAssertEqual(records.count, 1)

            expectation.fulfill()
        }

        let operation = ModifyOperation(records: [testRecord], recordIDsToDelete: [])
        session.dispatch(event: .doWork(.modify(operation)))
        session.dispatch(event: .accountStatusChanged(.available))

        wait(for: [expectation], timeout: 1)
    }

    func testHaltAfterPartialFailureWithoutRecovery() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = PartialFailureMockOperationHandler()
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneIdentifier: testZoneID
        )
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

        let operation = ModifyOperation(records: [testRecord], recordIDsToDelete: [])
        session.dispatch(event: .doWork(.modify(operation)))

        wait(for: [expectation], timeout: 1)
    }

    func testRetries() {
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = FailOnceMockOperationHandler(error: CKError(.networkUnavailable))
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneIdentifier: testZoneID
        )
        session.state = SyncState(hasGoodAccountStatus: true, hasCreatedZone: true)

        session.onRecordsModified = { records, _ in
            XCTAssertEqual(records.count, 1)

            expectation.fulfill()
        }

        let operation = ModifyOperation(records: [testRecord], recordIDsToDelete: [])
        session.dispatch(event: .doWork(.modify(operation)))

        wait(for: [expectation], timeout: 5)
    }
}
