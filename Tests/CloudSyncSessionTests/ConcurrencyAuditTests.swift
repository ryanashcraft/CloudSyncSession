@testable import CloudSyncSession
import CloudKit
import XCTest

final class ConcurrencyAuditTests: XCTestCase {
    private func makeSession(handler: OperationHandler = NeverCompletingMockOperationHandler()) -> CloudSyncSession {
        CloudSyncSession(
            operationHandler: handler,
            zoneID: CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName),
            resolveConflict: { _, _ in nil },
            resolveExpiredChangeToken: { nil }
        )
    }

    func testResetAfterHaltClearsHaltedStateBeforeSubsequentStart() {
        let session = makeSession()

        session.stop()
        session.reset()

        let expectation = expectation(description: "state settled")
        session.dispatchQueue.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertFalse(session.state.isHalted)
    }

    func testCrossThreadFetchResetAppendMiddlewareDoesNotCrash() {
        let session = makeSession()

        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            switch iteration % 3 {
            case 0:
                session.fetch(FetchOperation(changeToken: nil))
            case 1:
                session.reset()
            default:
                session.appendMiddleware(LoggerMiddleware(session: session))
            }
        }

        let expectation = expectation(description: "queue drained")
        session.dispatchQueue.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }
}

/// An operation handler that never calls any completion. Lets tests pin queue
/// contents and waiter behavior without work ever finishing.
final class NeverCompletingMockOperationHandler: OperationHandler {
    func handle(fetchOperation _: FetchOperation, completion _: @escaping (Result<FetchOperation.Response, Error>) -> Void) {}
    func handle(modifyOperation _: ModifyOperation, completion _: @escaping (Result<ModifyOperation.Response, Error>) -> Void) {}
    func handle(createZoneOperation _: CreateZoneOperation, completion _: @escaping (Result<Bool, Error>) -> Void) {}
    func handle(createSubscriptionOperation _: CreateSubscriptionOperation, completion _: @escaping (Result<Bool, Error>) -> Void) {}
}
