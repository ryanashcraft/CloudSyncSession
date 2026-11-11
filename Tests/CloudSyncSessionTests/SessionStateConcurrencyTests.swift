import CloudKit
@testable import CloudSyncSession
import Combine
@testable import SyncSessionCore
import XCTest

private let concurrencyTestZoneID = CKRecordZone.ID(
    zoneName: "ConcurrencyTests",
    ownerName: CKCurrentUserDefaultName
)

final class SessionStateConcurrencyTests: XCTestCase {
    private func makeSession() -> CloudSyncSession {
        CloudSyncSession(
            operationHandler: ScriptedOperationHandler(),
            zoneID: concurrencyTestZoneID,
            resolveConflict: { _, _ in nil },
            resolveExpiredChangeToken: { nil }
        )
    }

    /// Readers on other queues must tolerate a subscriber arriving concurrently.
    func testConcurrentReadsWhileSubscribing() {
        let session = makeSession()
        var tasks = Set<AnyCancellable>()
        let readerQueue = DispatchQueue(label: "reader", attributes: .concurrent)
        let reads = expectation(description: "reads")
        reads.expectedFulfillmentCount = 64

        for _ in 0 ..< 64 {
            readerQueue.async {
                _ = session.state.isRunning
                reads.fulfill()
            }
        }

        session.statePublisher
            .sink { _ in }
            .store(in: &tasks)

        session.accountStatusChanged(.available)

        wait(for: [reads], timeout: 5)
    }

    func testStatePublisherEmitsCurrentValueOnSubscribe() {
        let session = makeSession()
        var tasks = Set<AnyCancellable>()
        let received = expectation(description: "current value")

        session.accountStatusChanged(.available)

        // The session hands changes to observers from its own queue. Wait for that, so the value
        // below can only come from subscribing and not from the change being delivered.
        session.flushOutput()

        session.statePublisher
            .sink { state in
                if state.hasGoodAccountStatus == true {
                    received.fulfill()
                }
            }
            .store(in: &tasks)

        wait(for: [received], timeout: 1)
    }
}
