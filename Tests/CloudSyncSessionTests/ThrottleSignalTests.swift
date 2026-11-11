import CloudKit
@testable import CloudSyncSession
import XCTest

/// What `CloudKitOperationHandler` tells its throttle about each way a request can end.
final class ThrottleSignalTests: XCTestCase {
    func testSuccessIsNoPressure() {
        XCTAssertEqual(signal(for: nil), .noPressure)
    }

    // MARK: Errors about load

    func testAnErrorCarryingARetryAfterIsARequestedWait() {
        XCTAssertEqual(signal(for: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0])), .waitRequested(30))
        XCTAssertEqual(signal(for: CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 4.5])), .waitRequested(4.5))
    }

    func testALoadErrorWithoutARetryAfterIsPressure() {
        XCTAssertEqual(signal(for: CKError(.requestRateLimited)), .pressure)
        XCTAssertEqual(signal(for: CKError(.zoneBusy)), .pressure)
        XCTAssertEqual(signal(for: CKError(.serviceUnavailable)), .pressure)
    }

    // MARK: Errors about something else

    func testACloudKitErrorThatIsNotAboutLoadIsNoPressure() {
        XCTAssertEqual(signal(for: CKError(.serverRecordChanged)), .noPressure)
        XCTAssertEqual(signal(for: CKError(.networkUnavailable)), .noPressure)
        XCTAssertEqual(signal(for: CKError(.zoneNotFound)), .noPressure)
    }

    func testAnErrorThatIsNotFromCloudKitSaysNothing() {
        XCTAssertNil(signal(for: URLError(.timedOut)))
        XCTAssertNil(signal(for: CancellationError()))
    }

    // MARK: Partial failures

    func testAPartialFailureWhoseItemsAreAllRateLimitedAsksForTheLongestOfTheirWaits() {
        let error = makePartialFailure([
            CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 5.0]),
            CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 12.0]),
        ])

        XCTAssertEqual(signal(for: error), .waitRequested(12))
    }

    func testAPartialFailureWhoseItemsAreAllRateLimitedWithoutARetryAfterIsPressure() {
        let error = makePartialFailure([
            CKError(.requestRateLimited),
            CKError(.zoneBusy),
        ])

        XCTAssertEqual(signal(for: error), .pressure)
    }

    /// One item was rate limited and told how long to wait, the other failed for a reason that
    /// has nothing to do with load. The wait still stands.
    func testAMixedPartialFailureWithARetryAfterIsARequestedWait() {
        let error = makePartialFailure([
            CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 7.0]),
            CKError(.serverRecordChanged),
        ])

        XCTAssertEqual(signal(for: error), .waitRequested(7))
    }

    func testAMixedPartialFailureWithoutARetryAfterIsNoPressure() {
        let error = makePartialFailure([
            CKError(.zoneBusy),
            CKError(.serverRecordChanged),
        ])

        XCTAssertEqual(signal(for: error), .noPressure)
    }

    func testAPartialFailureWithNoItemAboutLoadIsNoPressure() {
        let error = makePartialFailure([
            CKError(.serverRecordChanged),
            CKError(.batchRequestFailed),
        ])

        XCTAssertEqual(signal(for: error), .noPressure)
    }

    // MARK: Helpers

    private func signal(for error: Error?) -> Throttle.Signal? {
        CloudKitOperationHandler.throttleSignal(forRequestEndingWith: error)
    }

    private func makePartialFailure(_ itemErrors: [CKError]) -> CKError {
        let zoneID = CKRecordZone.ID(zoneName: "ThrottleSignalTests", ownerName: CKCurrentUserDefaultName)
        var errorsByItemID: [CKRecord.ID: Error] = [:]

        for itemError in itemErrors {
            errorsByItemID[CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)] = itemError
        }

        return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: errorsByItemID])
    }
}
