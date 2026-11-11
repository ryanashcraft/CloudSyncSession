import CloudKit
import CloudSyncSession
import Combine
import XCTest

/// Uses the library the way an app does: through `import CloudSyncSession` alone, with no access
/// to anything internal. Most of what this file checks, it checks by compiling. If a name an app
/// depends on moves or changes shape, this file stops building.
final class AppFacingSurfaceTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    func testSessionCanBeBuiltAndDrivenThroughItsPublicNames() {
        let session = CloudSyncSession(
            operationHandler: SucceedingHandler(),
            zoneID: zoneID,
            accountStatusProvider: { .available },
            resolveConflict: { client, _ in client },
            resolveExpiredChangeToken: { nil }
        )
        let saved = expectation(description: "modify completed")
        let fetched = expectation(description: "fetch completed")

        session.modifyWorkCompletedSubject
            .first { [checkpointID] completed, _ in completed.checkpointID == checkpointID }
            .sink { _, response in
                XCTAssertEqual(response.savedRecords.count, 1)
                XCTAssertEqual(response.deletedRecordIDs.count, 0)
                saved.fulfill()
            }
            .store(in: &cancellables)

        session.fetchWorkCompletedSubject
            .sink { operation, response in
                _ = operation.id
                _ = (response.changeToken, response.changedRecords, response.deletedRecordIDs, response.hasMore)
                fetched.fulfill()
            }
            .store(in: &cancellables)

        session.start()
        session.modify(ModifyOperation(records: [makeRecord()], recordIDsToDelete: [], checkpointID: checkpointID, userInfo: nil))
        session.fetch(FetchOperation(changeToken: nil))

        wait(for: [saved, fetched], timeout: 5)

        let state: SyncState = session.state

        XCTAssertTrue(state.isRunning)
        XCTAssertFalse(state.isStarting)
        XCTAssertFalse(state.isHalted)
        XCTAssertEqual(state.hasGoodAccountStatus, true)
        XCTAssertEqual(state.hasCreatedZone, true)
        XCTAssertEqual(state.hasCreatedSubscription, true)
        XCTAssertEqual(state.retryCount, 0)
        XCTAssertNil(state.lastRetryError)
        XCTAssertNil(state.lastHaltedDate)
        _ = (state.isFetching, state.isModifying, state.hasWorkQueued)

        session.stop()

        let halted = expectation(description: "halt reported")

        session.haltedSubject
            .compactMap { $0 }
            .first()
            .sink { error in
                XCTAssertTrue(error is StopError)
                XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Stopped")
                halted.fulfill()
            }
            .store(in: &cancellables)

        wait(for: [halted], timeout: 5)

        session.reset()
    }

    func testEventsCanBeMatchedByTheCasesAnAppLooksFor() {
        let fetchFailure = SyncEvent.workFailure(.fetch(FetchOperation(changeToken: nil)), CKError(.networkUnavailable))
        let retry = SyncEvent.retry(.modify(makeModify()), CKError(.quotaExceeded), 315)
        let halt = SyncEvent.halt(CKError(.quotaExceeded))
        let queued = SyncEvent.doWork(.modify(makeModify()))

        XCTAssertNotNil(failedFetch(in: fetchFailure))
        XCTAssertNil(failedFetch(in: halt))
        XCTAssertEqual((storageError(in: retry) as? CKError)?.code, .quotaExceeded)
        XCTAssertEqual((storageError(in: halt) as? CKError)?.code, .quotaExceeded)
        XCTAssertNil(storageError(in: queued))

        if case let .doWork(.modify(operation)) = queued {
            XCTAssertNil(operation.checkpointID)
        } else {
            XCTFail("A queued modify should match .doWork(.modify)")
        }
    }

    /// Foodnoms reads the queued fetches and their change tokens by reflection, by these names.
    func testQueuedFetchesCanBeReadByReflection() {
        let session = CloudSyncSession(
            operationHandler: SucceedingHandler(),
            zoneID: zoneID,
            resolveConflict: { _, _ in nil },
            resolveExpiredChangeToken: { nil }
        )
        let operation = FetchOperation(changeToken: nil)

        session.fetch(operation)

        XCTAssertEqual(session.state.queuedFetches.map(\.id), [operation.id])
        XCTAssertTrue(operation.hasReflectedChangeToken)
    }

    func testEventsAndHaltsAreCurrentValueSubjects() {
        let session = CloudSyncSession(
            operationHandler: SucceedingHandler(),
            zoneID: zoneID,
            resolveConflict: { _, _ in nil },
            resolveExpiredChangeToken: { nil }
        )

        XCTAssertNil(session.eventsPublisher.value)
        XCTAssertNil(session.haltedSubject.value)
        XCTAssertNil(session.accountStatusSubject.value)

        session.eventsPublisher.dropFirst().sink { _ in }.store(in: &cancellables)
        session.statePublisher.map(\.hasWorkQueued).sink { _ in }.store(in: &cancellables)

        let registry = SessionRegistry()

        registry.register(session)
        XCTAssertTrue(registry.current === session)
    }

    // MARK: Helpers

    private let zoneID = CKRecordZone.ID(zoneName: "app-facing", ownerName: CKCurrentUserDefaultName)
    private let checkpointID = UUID()

    private func makeRecord() -> CKRecord {
        CKRecord(recordType: "Test", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
    }

    private func makeModify() -> ModifyOperation {
        ModifyOperation(records: [], recordIDsToDelete: [], checkpointID: nil, userInfo: nil)
    }

    private func failedFetch(in event: SyncEvent?) -> (FetchOperation, Error)? {
        if case let .workFailure(.fetch(operation), error) = event {
            return (operation, error)
        }

        return nil
    }

    private func storageError(in event: SyncEvent?) -> Error? {
        switch event {
        case let .retry(_, error, _), let .halt(error):
            return error
        default:
            return nil
        }
    }
}

// MARK: What an app adds to the library's types

private protocol Registrable: AnyObject {}

/// An app conforms the session to protocols of its own, such as a dependency key.
extension CloudSyncSession: Registrable {}

private final class SessionRegistry {
    private(set) var current: Registrable?

    func register(_ session: Registrable) {
        current = session
    }
}

extension StopError: @retroactive LocalizedError {
    public var errorDescription: String? {
        "Stopped"
    }
}

private extension SyncState {
    var queuedFetches: [FetchOperation] {
        Mirror(reflecting: self).descendant("fetchQueue") as? [FetchOperation] ?? []
    }
}

private extension FetchOperation {
    var hasReflectedChangeToken: Bool {
        Mirror(reflecting: self).children.contains { $0.label == "changeToken" }
    }
}

private final class SucceedingHandler: OperationHandler {
    func handle(fetchOperation: FetchOperation) async throws -> FetchOperation.Response {
        FetchOperation.Response(changeToken: fetchOperation.changeToken, changedRecords: [], deletedRecordIDs: [], hasMore: false)
    }

    func handle(modifyOperation: ModifyOperation) async throws -> ModifyOperation.Response {
        ModifyOperation.Response(savedRecords: modifyOperation.records, deletedRecordIDs: modifyOperation.recordIDsToDelete)
    }

    func handle(createZoneOperation _: CreateZoneOperation) async throws -> Bool {
        true
    }

    func handle(createSubscriptionOperation _: CreateSubscriptionOperation) async throws -> Bool {
        true
    }
}
