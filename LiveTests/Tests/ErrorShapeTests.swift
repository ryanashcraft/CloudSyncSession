import CloudKit
import CloudSyncSession
import XCTest

/// The shape of the errors the session's failure handling is built on, as CloudKit really
/// reports them through `CloudKitOperationHandler`.
final class ErrorShapeTests: XCTestCase {
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

    /// A conflict on one record of a batch must come back as a `partialFailure` whose per-record
    /// errors name the conflicted record and mark the rest as `batchRequestFailed`. CloudKit's
    /// newer result-block API reports success here instead, which is why the handler stays on the
    /// deprecated completion block.
    func testConflictOnOneRecordArrivesAsAPartialFailureWithPerRecordErrors() async throws {
        let original = LiveCloudKit.makeRecords(1, in: zoneID)[0]

        _ = try await modify(saving: [original]).get()

        // A fresh record with the same ID carries no change tag, so the server sees a conflict.
        let stale = CKRecord(recordType: original.recordType, recordID: original.recordID)
        stale["index"] = 99

        let bystander = LiveCloudKit.makeRecords(1, in: zoneID)[0]
        let result = await modify(saving: [stale, bystander])

        guard case let .failure(error) = result else {
            return XCTFail("A batch with a conflicted record was reported as a success")
        }

        noteObservation("conflict in a batch: \(describe(error))")

        let ckError = try XCTUnwrap(error as? CKError)
        let perRecord = try XCTUnwrap(ckError.partialErrorsByItemID as? [CKRecord.ID: Error])

        XCTAssertEqual(ckError.code, .partialFailure)
        XCTAssertEqual((perRecord[stale.recordID] as? CKError)?.code, .serverRecordChanged)
        XCTAssertNotNil((perRecord[stale.recordID] as? CKError)?.serverRecord, "The conflict must carry the server's copy of the record")
        XCTAssertEqual((perRecord[bystander.recordID] as? CKError)?.code, .batchRequestFailed)
    }

    /// Records what a fetch from a zone that has been deleted reports. The session recreates the
    /// zone on `zoneNotFound` and `userDeletedZone`.
    func testFetchFromADeletedZone() async throws {
        await LiveCloudKit.deleteZone(zoneID)

        do {
            _ = try await handler.handle(fetchOperation: FetchOperation(changeToken: nil))

            XCTFail("A fetch from a deleted zone was reported as a success")
        } catch {
            noteObservation("fetch from a deleted zone: \(describe(error))")
        }
    }

    private func modify(saving records: [CKRecord]) async -> Result<ModifyOperation.Response, Error> {
        let operation = ModifyOperation(records: records, recordIDsToDelete: [], checkpointID: nil, userInfo: nil)

        do {
            return .success(try await handler.handle(modifyOperation: operation))
        } catch {
            return .failure(error)
        }
    }
}
