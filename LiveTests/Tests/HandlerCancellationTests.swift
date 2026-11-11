import CloudKit
import CloudSyncSession
import XCTest

/// Cancelling a request made through `CloudKitOperationHandler`, which is what the session does
/// to the operation under way when it is stopped or reset.
final class HandlerCancellationTests: XCTestCase {
    private var zoneID: CKRecordZone.ID!
    private var handler: CloudKitOperationHandler!

    override func setUp() async throws {
        try await LiveCloudKit.requireAccount()

        zoneID = LiveCloudKit.makeZoneID()
        try await LiveCloudKit.createZone(zoneID)

        handler = CloudKitOperationHandler(database: LiveCloudKit.database, zoneID: zoneID, subscriptionID: "LiveTests-unused")
    }

    override func tearDown() async throws {
        if let zoneID {
            await LiveCloudKit.deleteZone(zoneID)
        }
    }

    /// A request that is already with CloudKit cannot be recalled, so the handler lets it finish
    /// and reports what really happened. It must not come back while the request could still
    /// reach the server.
    func testCancellingAModifyThatIsWithCloudKitLetsItFinish() async throws {
        let records = LiveCloudKit.makeRecords(200, in: zoneID)
        let request = makeModifyTask(saving: records)

        // Long enough for the operation to have been handed to CloudKit.
        try await Task.sleep(nanoseconds: 150_000_000)

        let cancelled = Date()
        request.cancel()

        let outcome = await request.value
        let waited = Date().timeIntervalSince(cancelled)

        noteObservation("handler modify cancelled while with CloudKit: returned after \(String(format: "%.2f", waited))s with \(outcome)")
        XCTAssertEqual(outcome, "success, \(records.count) saved")
        XCTAssertLessThan(waited, 30)

        let savedWhenItReturned = try await LiveCloudKit.recordCount(in: zoneID)

        try await Task.sleep(nanoseconds: 3_000_000_000)

        let savedLater = try await LiveCloudKit.recordCount(in: zoneID)

        noteObservation("handler modify cancelled while with CloudKit: \(savedWhenItReturned) records on the server when it returned, \(savedLater) three seconds later")
        XCTAssertEqual(savedLater, savedWhenItReturned, "Records reached the server after the cancelled request had returned")
    }

    /// After a request, the handler holds the next one back for a moment. One cancelled during
    /// that wait must never be sent.
    func testCancellingARequestTheHandlerIsHoldingBackNeverSendsIt() async throws {
        _ = try await handler.handle(modifyOperation: ModifyOperation(records: LiveCloudKit.makeRecords(1, in: zoneID), recordIDsToDelete: [], checkpointID: nil, userInfo: nil))

        let request = makeModifyTask(saving: LiveCloudKit.makeRecords(5, in: zoneID))

        let cancelled = Date()
        request.cancel()

        let outcome = await request.value
        let waited = Date().timeIntervalSince(cancelled)

        noteObservation("handler modify cancelled while held back: returned after \(String(format: "%.3f", waited))s with \(outcome)")
        XCTAssertLessThan(waited, 0.2, "A request that was never sent has nothing to wait for")

        try await Task.sleep(nanoseconds: 3_000_000_000)

        let saved = try await LiveCloudKit.recordCount(in: zoneID)

        XCTAssertEqual(saved, 1, "The cancelled request was sent anyway")
    }

    /// Starts a modify through the handler and reports how it ended, in words.
    private func makeModifyTask(saving records: [CKRecord]) -> Task<String, Never> {
        let operation = ModifyOperation(records: records, recordIDsToDelete: [], checkpointID: nil, userInfo: nil)

        return Task { [handler] in
            do {
                let response = try await handler!.handle(modifyOperation: operation)

                return "success, \(response.savedRecords.count) saved"
            } catch is CancellationError {
                return "CancellationError"
            } catch {
                return describe(error)
            }
        }
    }
}
