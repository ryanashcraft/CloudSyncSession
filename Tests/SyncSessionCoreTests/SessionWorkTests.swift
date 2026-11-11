@testable import SyncSessionCore
import XCTest

final class SyncWorkTests: XCTestCase {
    func testSplitPreservesCheckpointIDWhenThereAreNoDeletions() {
        let checkpointID = UUID()
        let operation = ModifyOperation(
            records: (0 ..< 900).map { _ in makeRecord() },
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
            records: (0 ..< 500).map { _ in makeRecord() },
            recordIDsToDelete: (0 ..< 500).map { _ in makeRecord().recordID },
            checkpointID: checkpointID,
            userInfo: nil
        )

        let chunks = operation.split

        XCTAssertEqual(chunks.last?.checkpointID, checkpointID)
        XCTAssertEqual(chunks.filter { $0.checkpointID != nil }.count, 1)
    }

    // MARK: Halving after the server rejects a request as too large

    func testSplitInHalfKeepsTheCheckpointOnTheSecondHalf() throws {
        let checkpointID = UUID()
        let operation = ModifyOperation(
            records: (0 ..< 5).map { _ in makeRecord() },
            recordIDsToDelete: (0 ..< 3).map { _ in makeRecord().recordID },
            checkpointID: checkpointID,
            userInfo: nil
        )

        let halves = try XCTUnwrap(operation.splitInHalf)

        XCTAssertEqual(halves.map(\.records.count), [2, 3])
        XCTAssertEqual(halves.map(\.recordIDsToDelete.count), [1, 2])
        XCTAssertEqual(halves.map(\.checkpointID), [nil, checkpointID])
    }

    func testSingleItemCannotBeSplitInHalf() {
        let oneSave = ModifyOperation(records: [makeRecord()], recordIDsToDelete: [], checkpointID: nil, userInfo: nil)
        let oneDeletion = ModifyOperation(records: [], recordIDsToDelete: [makeRecord().recordID], checkpointID: nil, userInfo: nil)

        XCTAssertNil(oneSave.splitInHalf)
        XCTAssertNil(oneDeletion.splitInHalf)
    }

    func testOneSaveAndOneDeletionSplitIntoTheSaveThenTheDeletion() throws {
        let operation = ModifyOperation(records: [makeRecord()], recordIDsToDelete: [makeRecord().recordID], checkpointID: UUID(), userInfo: nil)

        let halves = try XCTUnwrap(operation.splitInHalf)

        XCTAssertEqual(halves.map(\.records.count), [1, 0])
        XCTAssertEqual(halves.map(\.recordIDsToDelete.count), [0, 1])
        XCTAssertEqual(halves.map { $0.checkpointID != nil }, [false, true])
    }

    func testNeitherHalfIsEverEmpty() throws {
        for saves in 0 ... 4 {
            for deletions in 0 ... 4 where saves + deletions > 1 {
                let operation = ModifyOperation(
                    records: (0 ..< saves).map { _ in makeRecord() },
                    recordIDsToDelete: (0 ..< deletions).map { _ in makeRecord().recordID },
                    checkpointID: nil,
                    userInfo: nil
                )

                let halves = try XCTUnwrap(operation.splitInHalf)

                XCTAssertEqual(halves.count, 2)
                XCTAssertTrue(halves.allSatisfy { $0.records.count + $0.recordIDsToDelete.count > 0 }, "\(saves) saves, \(deletions) deletions")
                XCTAssertEqual(halves.reduce(0) { $0 + $1.records.count }, saves)
                XCTAssertEqual(halves.reduce(0) { $0 + $1.recordIDsToDelete.count }, deletions)
            }
        }
    }
}
