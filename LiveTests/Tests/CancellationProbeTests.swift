import CloudKit
import XCTest

/// What CloudKit does with an operation that is cancelled. The session's handling of `stop()` is
/// written against these answers, so they are recorded rather than assumed.
///
/// Each test fails only if a cancelled operation never finishes. Everything else is reported as a
/// `LIVE-OBSERVATION` line, because the point is to find out.
final class CancellationProbeTests: XCTestCase {
    private var zoneID: CKRecordZone.ID!

    override func setUp() async throws {
        try await LiveCloudKit.requireAccount()

        zoneID = LiveCloudKit.makeZoneID()
        try await LiveCloudKit.createZone(zoneID)
    }

    override func tearDown() async throws {
        if let zoneID {
            await LiveCloudKit.deleteZone(zoneID)
        }
    }

    func testModifyCancelledWhileExecuting() async throws {
        let records = LiveCloudKit.makeRecords(200, in: zoneID)
        let operation = makeModifyOperation(saving: records)

        let outcome = await run(operation, named: "modify") { operation in
            await waitUntilExecuting(operation)
            operation.cancel()
        }

        noteObservation("modify cancelled while executing: \(outcome)")

        let saved = try await LiveCloudKit.recordCount(in: zoneID)

        noteObservation("modify cancelled while executing: \(saved) of \(records.count) records are on the server afterwards")
    }

    func testModifyCancelledBeforeItStarts() async throws {
        let operation = makeModifyOperation(saving: LiveCloudKit.makeRecords(5, in: zoneID))

        operation.cancel()

        let outcome = await run(operation, named: "modify") { _ in }

        noteObservation("modify cancelled before it starts: \(outcome)")

        let saved = try await LiveCloudKit.recordCount(in: zoneID)

        XCTAssertEqual(saved, 0, "An operation cancelled before it started must not reach the server")
    }

    func testFetchCancelledWhileExecuting() async throws {
        let operation = makeFetchOperation()

        let outcome = await run(operation, named: "fetch") { operation in
            await waitUntilExecuting(operation)
            operation.cancel()
        }

        noteObservation("fetch cancelled while executing: \(outcome)")
    }

    func testFetchCancelledBeforeItStarts() async throws {
        let operation = makeFetchOperation()

        operation.cancel()

        let outcome = await run(operation, named: "fetch") { _ in }

        noteObservation("fetch cancelled before it starts: \(outcome)")
    }

    // MARK: Operations, configured as CloudKitOperationHandler configures them

    /// The CloudKit-specific callback of the operation under test, set by the `make…` functions
    /// and reported through these notes.
    private let notes = Notes()

    private func makeModifyOperation(saving records: [CKRecord]) -> CKModifyRecordsOperation {
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)

        operation.modifyRecordsCompletionBlock = { [notes] savedRecords, _, error in
            notes.add("CloudKit completion block ran: \(savedRecords?.count ?? 0) saved, \(describe(error))")
        }

        operation.savePolicy = .ifServerRecordUnchanged
        operation.qualityOfService = .userInitiated
        operation.database = LiveCloudKit.database

        return operation
    }

    private func makeFetchOperation() -> CKFetchRecordZoneChangesOperation {
        let operation = CKFetchRecordZoneChangesOperation()

        operation.configurationsByRecordZoneID = [
            zoneID: CKFetchRecordZoneChangesOperation.ZoneConfiguration(previousServerChangeToken: nil, resultsLimit: 400, desiredKeys: nil),
        ]
        operation.recordZoneIDs = [zoneID]
        operation.fetchAllChanges = false

        operation.recordZoneFetchResultBlock = { [notes] _, result in
            switch result {
            case .success:
                notes.add("zone result block ran: success")
            case let .failure(error):
                notes.add("zone result block ran: \(describe(error))")
            }
        }

        operation.fetchRecordZoneChangesResultBlock = { [notes] result in
            switch result {
            case .success:
                notes.add("CloudKit completion block ran: success")
            case let .failure(error):
                notes.add("CloudKit completion block ran: \(describe(error))")
            }
        }

        operation.qualityOfService = .userInitiated
        operation.database = LiveCloudKit.database

        return operation
    }

    // MARK: Running

    /// Adds the operation to a queue, runs `interfere`, and waits for the operation to finish.
    /// Returns the callbacks that ran, in order.
    private func run<Op: Operation>(_ operation: Op, named name: String, interfere: (Op) async -> Void) async -> String {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        let finished = expectation(description: "\(name) operation finished")

        // Foundation runs this once the operation is finished, whatever CloudKit does.
        operation.completionBlock = { [notes] in
            notes.add("operation finished (isCancelled: \(operation.isCancelled))")
            finished.fulfill()
        }

        queue.addOperation(operation)

        await interfere(operation)

        await fulfillment(of: [finished], timeout: 60)

        // CloudKit's own block may be delivered just after the operation is marked finished.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let all = notes.all

        if !all.contains(where: { $0.hasPrefix("CloudKit completion block ran") }) {
            notes.add("CloudKit completion block did NOT run within 2 seconds of the operation finishing")
        }

        return notes.all.joined(separator: "; ")
    }

    private func waitUntilExecuting(_ operation: Operation) async {
        let deadline = Date().addingTimeInterval(30)

        while !operation.isExecuting, !operation.isFinished, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // Give the request a moment to leave the device.
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
