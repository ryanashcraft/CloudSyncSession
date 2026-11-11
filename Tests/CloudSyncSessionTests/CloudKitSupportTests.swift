import CloudKit
@testable import CloudSyncSession
import XCTest

/// Unit tests for the pieces that sit between the session and CloudKit and can be checked without
/// a CloudKit container.
final class CloudKitSupportTests: XCTestCase {
    func testFetchResponseBuilderFailsWhenRecordZoneFetchFails() {
        let error = CKError(.zoneNotFound)
        var builder = FetchOperationResponseBuilder(changeToken: nil)

        builder.recordZoneFetchFailed(error)

        switch builder.response() {
        case .success:
            XCTFail("Expected record-zone fetch failure to fail the fetch operation")
        case let .failure(receivedError as CKError):
            XCTAssertEqual(receivedError.code, .zoneNotFound)
        case let .failure(receivedError):
            XCTFail("Expected CKError.zoneNotFound, received \(receivedError)")
        }
    }

    func testFetchResponseBuilderFailsWhenRecordFetchFails() {
        let error = CKError(.assetNotAvailable)
        var builder = FetchOperationResponseBuilder(changeToken: nil)

        builder.recordFetchFailed(error)

        switch builder.response() {
        case .success:
            XCTFail("Expected record fetch failure to fail the fetch operation")
        case let .failure(receivedError as CKError):
            XCTAssertEqual(receivedError.code, .assetNotAvailable)
        case let .failure(receivedError):
            XCTFail("Expected CKError.assetNotAvailable, received \(receivedError)")
        }
    }

    func testMissingSubscriptionIsReportedAsNotExisting() {
        let result = SubscriptionExistenceResult(subscriptionFetchError: CKError(.unknownItem), foundSubscription: false)

        switch result.result {
        case let .success(exists):
            XCTAssertFalse(exists)
        case let .failure(error):
            XCTFail("Expected missing subscription to be reported as not existing, received \(error)")
        }
    }

    // MARK: - CKRecord Extensions

    func testCKRecordRemoveAllFields() {
        let record = makeRecord()
        record["hello"] = "world"
        record.encryptedValues["secrets"] = "👻"

        record.removeAllFields()

        XCTAssertEqual(record["hello"] as! String?, nil)
        XCTAssertEqual(record["secrets"] as! String?, nil)
    }

    func testCKRecordCopyFields() {
        let recordA = makeRecord()
        recordA["hello"] = "world"
        recordA.encryptedValues["secrets"] = "👻"

        let recordB = makeRecord()
        recordB["hello"] = "🌎"
        recordA.encryptedValues["secrets"] = "💀"

        recordA.copyFields(from: recordB)

        XCTAssertEqual(recordA["hello"] as! String?, "🌎")
        XCTAssertEqual(recordA.encryptedValues["secrets"] as! String?, "💀")
    }
}
