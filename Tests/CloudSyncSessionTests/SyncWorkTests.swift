@testable import CloudSyncSession
import CloudKit
import XCTest

final class SyncWorkTests: XCTestCase {
    func testSplitPreservesCheckpointIDWhenThereAreNoDeletions() {
        let checkpointID = UUID()
        let operation = ModifyOperation(
            records: (0 ..< 900).map { _ in makeTestRecord() },
            recordIDsToDelete: [],
            checkpointID: checkpointID,
            userInfo: nil
        )

        let chunks = operation.split

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.last?.checkpointID, checkpointID)
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.checkpointID == nil })
    }

    func testSplitKeepsCheckpointIDOnLastDeleteChunkWhenDeletionsExist() {
        let checkpointID = UUID()
        let operation = ModifyOperation(
            records: (0 ..< 500).map { _ in makeTestRecord() },
            recordIDsToDelete: (0 ..< 500).map { _ in makeTestRecord().recordID },
            checkpointID: checkpointID,
            userInfo: nil
        )

        let chunks = operation.split

        XCTAssertEqual(chunks.last?.checkpointID, checkpointID)
        XCTAssertEqual(chunks.filter { $0.checkpointID != nil }.count, 1)
    }
}
