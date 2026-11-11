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
    case start, halt, accountStatusChanged, doWork, retryWork, workFailure, workSuccess, resolveConflict, retry, split
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
/// into the session's state or events, and they keep working when those change.
/// Whatever the session's interface becomes, this file is the one place that adapts to it.
///
/// The session's waits (the gap before work, the backoff before a retry) end at once unless a
/// test holds them, so nothing here runs in real time.
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
    private let pacing = ScriptedPacing()

    init(conflictPolicy: ConflictPolicy = .clientWins) {
        session = CloudSyncSession(
            operationHandler: handler,
            zoneID: CKRecordZone.ID(zoneName: "harness", ownerName: CKCurrentUserDefaultName),
            accountStatusProvider: nil,
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
            resolveExpiredChangeToken: { nil },
            pacing: pacing.pacing
        )

        // Stands in for an account status provider, which needs a real CKContainer.
        session.accountStatusChanged(.available)

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

    /// Calls the session's `stopAndWait()` in the background. The returned closure reports, whenever
    /// it is asked, whether that call has returned yet.
    func beginStopAndWait() -> () -> Bool {
        let hasReturned = Flag()

        Task { [session] in
            await session.stopAndWait()

            hasReturned.set()
        }

        return { hasReturned.isSet }
    }

    /// Resets the session, which also forgets the account status.
    func reset() {
        session.reset()
    }

    /// Tells the session whether the iCloud account can be used.
    func setAccountAvailable(_ isAvailable: Bool) {
        session.accountStatusChanged(isAvailable ? .available : .noAccount)
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

    /// Waits until the session has nothing left to do and has reported everything it did. That is
    /// the case when its queue is empty, when it is halted, and when it is waiting for the account
    /// to become available.
    ///
    /// Records a test failure and returns false if that does not happen within `timeout`. It cannot
    /// happen while a test is holding a wait or a reply.
    @discardableResult
    func settle(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            guard isQuiet else {
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))

                continue
            }

            deliverPendingOutput()

            // An observer may have queued more work while it was being told about the last of it.
            if isQuiet {
                return true
            }
        }

        XCTFail("Session did not settle within \(timeout)s. Handler calls so far: \(handler.calls.count)", file: file, line: line)

        return false
    }

    /// Spins the main run loop until `condition` holds. Records a test failure and returns false
    /// if it does not within `timeout`.
    @discardableResult
    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if condition() {
                return true
            }

            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }

        XCTFail("Timed out waiting until \(description)", file: file, line: line)

        return false
    }

    /// Spins the main run loop for a moment, to give something that should not happen the chance to.
    func idle(for duration: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    // MARK: Holding the session mid-flight

    /// Holds the session in the gap it leaves before sending work, until `releaseWaits()` or until
    /// the session itself cuts the wait short.
    func holdWorkDelay() {
        pacing.holdWorkDelay()
    }

    /// Holds the session in its wait before a retry, in the same way.
    func holdRetryBackoff() {
        pacing.holdRetryBackoff()
    }

    func releaseWaits() {
        pacing.release()
    }

    /// Waits until the session has reached a wait that is being held.
    func waitUntilWaiting(file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("the session is in a held wait", file: file, line: line) { pacing.isHolding }
    }

    /// Waits until a request has reached the handler and its reply is being held.
    func waitUntilReplyIsHeld(file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("a reply is being held", file: file, line: line) { handler.hasHeldReply }
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

    /// How long the session waited before each retry, in seconds and in order.
    var retryBackoffs: [TimeInterval] {
        pacing.retryBackoffs
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

    /// Runs a session through startup and one modify, drops every reference to it, and reports
    /// whether it was deallocated.
    static func sessionIsReleasedAfterWorking() -> Bool {
        weak var weakSession: CloudSyncSession?

        autoreleasepool {
            let harness = SessionHarness()

            harness.startRunning()
            harness.modify("A")
            harness.settle()
            harness.shutDown()

            weakSession = harness.session
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        return weakSession == nil
    }

    // MARK: Private

    /// Nothing is under way in the session or at the handler, so nothing more will happen until
    /// the test does something.
    private var isQuiet: Bool {
        session.isIdle && handler.isIdle
    }

    /// Returns once observers have been told about everything the session has done so far.
    private func deliverPendingOutput() {
        session.flushOutput()

        // Completions are delivered on the main queue. This block runs after the ones the flush
        // queued there.
        var isDelivered = false

        DispatchQueue.main.async {
            isDelivered = true
        }

        while !isDelivered {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

/// A boolean that can be set from one thread and read from another.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }

        return value
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }

        value = true
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
