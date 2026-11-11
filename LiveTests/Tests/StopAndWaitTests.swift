import CloudKit
import CloudSyncSession
import Combine
import XCTest

/// The sequence behind "Delete All Data": stop the session, delete the zone, and check that
/// nothing the session had already sent brings the zone back.
final class StopAndWaitTests: XCTestCase {
    private var zoneID: CKRecordZone.ID!
    private var subscriptionID: String!

    override func setUp() async throws {
        try await LiveCloudKit.requireAccount()

        zoneID = LiveCloudKit.makeZoneID()
        subscriptionID = "LiveTests-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        if let zoneID {
            await LiveCloudKit.deleteZone(zoneID)
        }

        if let subscriptionID {
            _ = try? await LiveCloudKit.database.deleteSubscription(withID: subscriptionID)
        }
    }

    func testNothingBringsTheZoneBackAfterStopAndWait() async throws {
        let session = CloudSyncSession(
            operationHandler: CloudKitOperationHandler(database: LiveCloudKit.database, zoneID: zoneID, subscriptionID: subscriptionID),
            zoneID: zoneID,
            accountStatusProvider: CloudSyncSession.accountStatusProvider(for: LiveCloudKit.container),
            resolveConflict: { client, _ in client },
            resolveExpiredChangeToken: { nil }
        )

        session.start()
        try await waitUntil("the session is running", timeout: 60) { session.state.isRunning }

        // Several requests' worth of work, so that stopping lands while one is under way and
        // others are still queued.
        for _ in 0 ..< 5 {
            session.modify(ModifyOperation(records: LiveCloudKit.makeRecords(100, in: zoneID), recordIDsToDelete: [], checkpointID: nil, userInfo: nil))
        }

        try await waitUntil("a modify is under way", timeout: 30) { session.state.isModifying }

        // Long enough for the first request to have left the session's own short wait and be
        // with the operation handler, which is the case this test is about.
        try await Task.sleep(nanoseconds: 400_000_000)

        let stopStarted = Date()

        await session.stopAndWait()

        noteObservation("stopAndWait returned after \(String(format: "%.2f", Date().timeIntervalSince(stopStarted)))s with work queued: \(session.state.hasWorkQueued)")

        session.reset()
        await LiveCloudKit.deleteZone(zoneID)

        // Anything that was going to arrive late has had time to.
        try await Task.sleep(nanoseconds: 5_000_000_000)

        let zoneExists = try await LiveCloudKit.zoneExists(zoneID)

        noteObservation("zone exists 5s after stopAndWait, reset and deleting it: \(zoneExists)")

        XCTAssertFalse(zoneExists, "The zone came back after it was deleted")
        XCTAssertFalse(session.state.hasWorkQueued)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting until \(description)")

                throw CancellationError()
            }

            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
