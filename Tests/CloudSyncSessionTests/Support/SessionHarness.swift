import CloudKit
@testable import CloudSyncSession
import Combine
import XCTest

/// One piece of finished work the session reported to its observers.
enum Completion: Equatable, CustomStringConvertible {
    case modify(_ tag: String, saved: Int, deleted: Int = 0, checkpointed: Bool = false)
    case fetch(changed: Int, hasMore: Bool)

    var description: String {
        switch self {
        case let .modify(tag, saved, deleted, checkpointed):
            return "modify(\(tag), saved: \(saved), deleted: \(deleted), checkpointed: \(checkpointed))"
        case let .fetch(changed, hasMore):
            return "fetch(changed: \(changed), hasMore: \(hasMore))"
        }
    }
}

/// The kinds of event the session announces, without their payloads.
enum ObservedEvent: Equatable {
    case start, halt, accountStatusChanged, doWork, retryWork, workFailure, workSuccess, resolveConflict, retry, split, noop
}

/// What the session's conflict resolver does when a save collides with a newer server record.
enum ConflictPolicy {
    case clientWins
    case serverWins
    case unresolvable
}

/// Drives a real `CloudSyncSession` against a `ScriptedOperationHandler` and reports what happened
/// in terms that do not depend on how the session is built.
///
/// Behavior tests talk only to this type. They never import the library, so they cannot reach
/// into the session's state, events, or middleware, and they keep working when those change.
/// Whatever the session's interface becomes, this file is the one place that adapts to it.
///
/// Use it from the main thread: `settle` spins the main run loop, which is also where the
/// session delivers completions.
final class SessionHarness {
    let handler = ScriptedOperationHandler()

    /// Completions in the order the session reported them.
    private(set) var completions: [Completion] = []

    /// How many saved records came back still carrying the fake server's marker, meaning the
    /// server's copy of a conflicted record was what ended up saved.
    private(set) var savedServerCopyCount = 0

    private let session: CloudSyncSession
    private var cancellables = Set<AnyCancellable>()
    private let eventsLock = NSLock()
    private var observedEvents: [ObservedEvent] = []
    private var startupCallCount = 0

    /// How long the session must stay idle before `settle` believes it. It has to outlast the
    /// session's own delay between queueing work and handing it to the handler.
    private static let quietPeriod: TimeInterval = 0.25

    init(conflictPolicy: ConflictPolicy = .clientWins) {
        session = CloudSyncSession(
            operationHandler: handler,
            zoneID: CKRecordZone.ID(zoneName: "harness", ownerName: CKCurrentUserDefaultName),
            resolveConflict: { clientRecord, serverRecord in
                switch conflictPolicy {
                case .clientWins:
                    return clientRecord
                case .serverWins:
                    return serverRecord
                case .unresolvable:
                    return nil
                }
            },
            resolveExpiredChangeToken: { nil }
        )

        // Stands in for AccountStatusMiddleware, which needs a real CKContainer. Done before
        // anything is dispatched so it cannot interleave with the session's own state updates.
        var state = session.state
        state.hasGoodAccountStatus = true
        session.state = state

        session.modifyWorkCompletedSubject
            .sink { [weak self] operation, response in
                self?.completions.append(
                    .modify(
                        operation.tag,
                        saved: response.savedRecords.count,
                        deleted: response.deletedRecordIDs.count,
                        checkpointed: operation.checkpointID != nil
                    )
                )
                self?.savedServerCopyCount += response.savedRecords.filter { $0[serverCopyMarkerKey] != nil }.count
            }
            .store(in: &cancellables)

        session.fetchWorkCompletedSubject
            .sink { [weak self] _, response in
                self?.completions.append(.fetch(changed: response.changedRecords.count, hasMore: response.hasMore))
            }
            .store(in: &cancellables)

        session.eventsPublisher
            .sink { [weak self] event in
                guard let self, let event else {
                    return
                }

                self.eventsLock.lock()
                self.observedEvents.append(ObservedEvent(event))
                self.eventsLock.unlock()
            }
            .store(in: &cancellables)
    }

    // MARK: Driving the session

    /// Starts the session and waits until it has created its zone and subscription and has
    /// worked through anything that was queued beforehand.
    func startRunning(file: StaticString = #filePath, line: UInt = #line) {
        session.start()

        guard settle(file: file, line: line) else {
            return
        }

        XCTAssertTrue(session.state.isRunning, "Session did not reach the running state", file: file, line: line)

        startupCallCount = handler.calls.prefix { $0.isSetup }.count
    }

    func start() {
        session.start()
    }

    func stop() {
        session.stop()
    }

    /// Queues a modify operation labelled with `tag`.
    func modify(_ tag: String, saves: Int = 1, deletes: Int = 0, checkpoint: Bool = false) {
        session.modify(
            ModifyOperation(
                records: (0 ..< saves).map { _ in makeRecord() },
                recordIDsToDelete: (0 ..< deletes).map { _ in makeRecord().recordID },
                checkpointID: checkpoint ? UUID() : nil,
                userInfo: [ModifyOperation.tagKey: tag]
            )
        )
    }

    /// Queues a fetch from the beginning of the zone.
    func fetch() {
        session.fetch(FetchOperation(changeToken: nil))
    }

    /// Waits until the session has nothing left to do: no request outstanding at the handler and
    /// either no work queued or the session halted, continuously for a short quiet period.
    ///
    /// Records a test failure and returns false if that does not happen within `timeout`.
    @discardableResult
    func settle(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var quietSince: Date?

        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))

            guard isQuiet else {
                quietSince = nil

                continue
            }

            if let quietSince {
                if Date().timeIntervalSince(quietSince) >= Self.quietPeriod {
                    return true
                }
            } else {
                quietSince = Date()
            }
        }

        XCTFail("Session did not settle within \(timeout)s. Handler calls so far: \(handler.calls.count)", file: file, line: line)

        return false
    }

    /// Halts the session so nothing keeps running after the test. Registered by `makeHarness`.
    func shutDown() {
        session.stop()
        cancellables.removeAll()
    }

    // MARK: Observing the session

    /// Every request the handler received, in order.
    var calls: [HandlerCall] {
        handler.calls
    }

    /// Requests the handler received after the zone and subscription were set up by `startRunning`.
    var workCalls: [HandlerCall] {
        Array(handler.calls.dropFirst(startupCallCount))
    }

    var isHalted: Bool {
        session.state.isHalted
    }

    var hasWorkQueued: Bool {
        session.state.hasWorkQueued
    }

    /// The CloudKit error code the session halted with, if it halted on a CloudKit error.
    var haltCode: CKError.Code? {
        (session.haltedSubject.value as? CKError)?.code
    }

    /// How many times the session announced an event of this kind.
    func eventCount(_ kind: ObservedEvent) -> Int {
        eventsLock.lock()
        defer { eventsLock.unlock() }

        return observedEvents.filter { $0 == kind }.count
    }

    /// Creates a session, drops every reference to it, and reports whether it was deallocated.
    static func sessionIsReleasedWhenDropped() -> Bool {
        weak var weakSession: CloudSyncSession?

        autoreleasepool {
            let session = CloudSyncSession(
                operationHandler: ScriptedOperationHandler(),
                zoneID: CKRecordZone.ID(zoneName: "harness", ownerName: CKCurrentUserDefaultName),
                resolveConflict: { _, _ in nil },
                resolveExpiredChangeToken: { nil }
            )

            weakSession = session
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        return weakSession == nil
    }

    // MARK: Private

    private var isQuiet: Bool {
        let state = session.state

        return handler.isIdle && (state.isHalted || !state.hasWorkQueued)
    }
}

private extension ObservedEvent {
    init(_ event: SyncEvent) {
        switch event {
        case .start:
            self = .start
        case .halt:
            self = .halt
        case .accountStatusChanged:
            self = .accountStatusChanged
        case .doWork:
            self = .doWork
        case .retryWork:
            self = .retryWork
        case .workFailure:
            self = .workFailure
        case .workSuccess:
            self = .workSuccess
        case .resolveConflict:
            self = .resolveConflict
        case .retry:
            self = .retry
        case .split:
            self = .split
        case .noop:
            self = .noop
        }
    }
}

extension XCTestCase {
    /// Creates a harness that is shut down when the test finishes.
    func makeHarness(conflictPolicy: ConflictPolicy = .clientWins) -> SessionHarness {
        let harness = SessionHarness(conflictPolicy: conflictPolicy)

        addTeardownBlock {
            harness.shutDown()
        }

        return harness
    }
}
