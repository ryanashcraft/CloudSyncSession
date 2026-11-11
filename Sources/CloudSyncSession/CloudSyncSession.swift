import CloudKit
import Combine

public typealias ConflictResolver = (CKRecord, CKRecord) -> CKRecord?
public typealias ChangeTokenExpiredResolver = () -> CKServerChangeToken?

public struct StopError: Error {}

/// An object that manages a long-lived series of CloudKit syncing operations.
///
/// The session keeps four queues of work (create zone, create subscription, modify, fetch) in its
/// `state`. Every method here changes that state in one step, under a lock, on the caller's thread.
/// A single task, the run loop in `CloudSyncSession+RunLoop.swift`, then sends the work at the head
/// of the queue to the operation handler, one piece at a time.
///
/// All mutable state is guarded by `lock`, which is what makes the type safe to share across threads.
public class CloudSyncSession: @unchecked Sendable {
    /// Represents the state of the session.
    public var state: SyncState {
        lock.lock()
        defer { lock.unlock() }

        return lockedState
    }

    /// A Combine publisher that publishes the state, starting with the current value.
    public var statePublisher: AnyPublisher<SyncState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    /// Handles fetch, modify, create zone, and create subscription operations.
    let operationHandler: OperationHandler

    /// The CloudKit zone ID.
    let zoneID: CKRecordZone.ID

    /// The function handler that will be called to resolve record conflicts.
    public let resolveConflict: ConflictResolver?

    /// The function handler that will be called when the change token should be expired.
    public let resolveExpiredChangeToken: ChangeTokenExpiredResolver?

    /// A Combine subject that publishes the most recent event.
    public let eventsPublisher = CurrentValueSubject<SyncEvent?, Never>(nil)

    /// A Combine subject that publishes fetch work that has completed.
    public let fetchWorkCompletedSubject = PassthroughSubject<(FetchOperation, FetchOperation.Response), Never>()

    /// A Combine subject that publishes modify work that has completed.
    public let modifyWorkCompletedSubject = PassthroughSubject<(ModifyOperation, ModifyOperation.Response), Never>()

    /// A Combine subject that signals when the session has halted due to an error.
    public let haltedSubject = CurrentValueSubject<Error?, Never>(nil)

    /// A Combine subject that publishes the latest iCloud account status.
    public let accountStatusSubject = CurrentValueSubject<CKAccountStatus?, Never>(nil)

    let accountStatusProvider: AccountStatusProvider?
    let failureResolver: FailureResolver
    let pacing: Pacing

    /// Guards `lockedState`, `runLoopTask`, `cancelCurrentStep`, and `isLookingUpAccountStatus`.
    let lock = NSLock()
    var lockedState = SyncState()
    var runLoopTask: Task<Void, Never>?

    /// Cancels what the run loop is waiting on right now: a wait of its own, or an operation that
    /// is with the operation handler. Nil when it is waiting on neither.
    var cancelCurrentStep: (@Sendable () -> Void)?
    private var isLookingUpAccountStatus = false

    private let stateSubject = CurrentValueSubject<SyncState, Never>(SyncState())

    /// Delivers events and state to observers in the order the changes were made, without holding the lock.
    private let outputQueue = DispatchQueue(label: "CloudSyncSession.Output", qos: .userInitiated)

    /**
     Creates a session.

     - Parameter operationHandler: The object that handles fetch, modify, create zone, and create subscription operations.
     - Parameter zoneID: The CloudKit zone ID.
     - Parameter accountStatusProvider: Looks up the iCloud account status. Called from `start()` whenever the status is not known. Without one, the app must call `accountStatusChanged(_:)` itself before any work can run.
     - Parameter resolveConflict: The function handler that will be called to resolve record conflicts.
     - Parameter resolveExpiredChangeToken: The function handler that will be called when the change token should be expired.
     */
    public convenience init(
        operationHandler: OperationHandler,
        zoneID: CKRecordZone.ID,
        accountStatusProvider: AccountStatusProvider? = nil,
        resolveConflict: @escaping ConflictResolver,
        resolveExpiredChangeToken: @escaping ChangeTokenExpiredResolver
    ) {
        self.init(
            operationHandler: operationHandler,
            zoneID: zoneID,
            accountStatusProvider: accountStatusProvider,
            resolveConflict: resolveConflict,
            resolveExpiredChangeToken: resolveExpiredChangeToken,
            pacing: .live
        )
    }

    init(
        operationHandler: OperationHandler,
        zoneID: CKRecordZone.ID,
        accountStatusProvider: AccountStatusProvider?,
        resolveConflict: @escaping ConflictResolver,
        resolveExpiredChangeToken: @escaping ChangeTokenExpiredResolver,
        pacing: Pacing
    ) {
        self.operationHandler = operationHandler
        self.zoneID = zoneID
        self.accountStatusProvider = accountStatusProvider
        self.resolveConflict = resolveConflict
        self.resolveExpiredChangeToken = resolveExpiredChangeToken
        self.pacing = pacing
        failureResolver = FailureResolver(
            resolveConflict: resolveConflict,
            resolveExpiredChangeToken: resolveExpiredChangeToken
        )
    }

    // MARK: Lifecycle

    /// Start the session, or resume it after it halted. Queued work is kept across a halt.
    public func start() {
        let shouldLookUpAccountStatus: Bool = update { change in
            change.emit(.start)
            change.state.isHalted = false

            if change.state.hasCreatedZone == nil, change.state.createZoneQueue.isEmpty {
                let work = SyncWork.createZone(CreateZoneOperation(zoneID: zoneID))

                change.emit(.doWork(work))
                change.state.enqueue(work)
            }

            if change.state.hasCreatedSubscription == nil, change.state.createSubscriptionQueue.isEmpty {
                let work = SyncWork.createSubscription(CreateSubscriptionOperation(zoneID: zoneID))

                change.emit(.doWork(work))
                change.state.enqueue(work)
            }

            change.state.updateOperationMode()

            guard change.state.hasGoodAccountStatus == nil, accountStatusProvider != nil, !isLookingUpAccountStatus else {
                return false
            }

            isLookingUpAccountStatus = true

            return true
        }

        if shouldLookUpAccountStatus, let accountStatusProvider {
            Task {
                let status = await accountStatusProvider()

                self.accountStatusChanged(status, finishesLookup: true)
            }
        }
    }

    /// Stop/halt the session.
    ///
    /// The session stops sending work, and a wait before work or before a retry ends at once. Queued
    /// work is kept for the next `start()`. An operation that is with the operation handler is
    /// cancelled. What that does is up to the handler: `CloudKitOperationHandler` drops a request it
    /// has not sent yet and lets one that is already with CloudKit finish, because CloudKit cannot
    /// recall it. If the operation succeeds, that is reported. Otherwise its work stays queued.
    ///
    /// This returns immediately, before that operation has wound down. Use `stopAndWait()` when
    /// what comes next must not overlap with it.
    public func stop() {
        _ = halt()
    }

    /// Stops the session as `stop()` does, then waits until the operation that was with the operation
    /// handler, if there was one, has finished or been cancelled.
    ///
    /// Use this before anything destructive, such as deleting the zone. After it returns, nothing
    /// this session sent before the call can still reach the server.
    ///
    /// The wait lasts as long as the operation handler takes to wind down the one cancelled
    /// operation. With `CloudKitOperationHandler` that is no time for a request it had not sent
    /// yet, and the rest of the round trip for one that is already with CloudKit.
    ///
    /// If `start()` is called before this returns, it returns once the session next runs out of work.
    public func stopAndWait() async {
        await halt()?.value
    }

    /// Reset the session state. Queued work is discarded. An operation that is with the operation
    /// handler is cancelled, and its result is ignored if one still arrives.
    public func reset() {
        update { change in
            cancelCurrentStep?()
            change.state = SyncState()
        }
    }

    /// Tell the session the iCloud account status. No work is sent until the account is available.
    public func accountStatusChanged(_ status: CKAccountStatus) {
        accountStatusChanged(status, finishesLookup: false)
    }

    // MARK: Work

    /// Queue a fetch operation. A fetch from a change token that is already queued is ignored.
    public func fetch(_ operation: FetchOperation) {
        update { change in
            guard !change.state.hasQueuedFetch(from: operation.changeToken) else {
                return
            }

            let work = SyncWork.fetch(operation)

            change.emit(.doWork(work))
            change.state.enqueue(work)
        }
    }

    /// Queue a modify operation. An operation with more records than fit in one request is queued as
    /// several, in order, with nothing else in between.
    public func modify(_ operation: ModifyOperation) {
        update { change in
            for piece in operation.shouldSplit ? operation.split : [operation] {
                let work = SyncWork.modify(piece)

                change.emit(.doWork(work))
                change.state.enqueue(work)
            }
        }
    }

    // MARK: State changes

    /// A change to the session being made under the lock: the state to store and the events to announce.
    struct Change {
        var state: SyncState
        fileprivate(set) var events: [SyncEvent] = []

        mutating func emit(_ event: SyncEvent) {
            events.append(event)
        }
    }

    /// Makes one change to the session under the lock, publishes it, and makes sure the run loop is
    /// running if the change left work to do.
    ///
    /// `body` must not call back into the session's public methods.
    @discardableResult
    func update<Value>(_ body: (inout Change) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }

        var change = Change(state: lockedState)
        let value = body(&change)

        lockedState = change.state

        let events = change.events
        let state = change.state

        // Queued while the lock is held so that observers see changes in the order they were made.
        outputQueue.async {
            for event in events {
                self.publish(event)
            }

            self.stateSubject.send(state)
        }

        startRunLoopIfNeeded()

        return value
    }

    private func halt() -> Task<Void, Never>? {
        update { change in
            change.emit(.halt(StopError()))
            change.state.isHalted = true

            cancelCurrentStep?()

            return runLoopTask
        }
    }

    private func accountStatusChanged(_ status: CKAccountStatus, finishesLookup: Bool) {
        update { change in
            if finishesLookup {
                isLookingUpAccountStatus = false
            }

            change.emit(.accountStatusChanged(status))
            change.state.hasGoodAccountStatus = status == .available
            change.state.updateOperationMode()
        }
    }

    /// Announces one event: logs it, sends it to `eventsPublisher`, and forwards it to whichever
    /// of the other subjects reports that kind of event. Runs on the output queue.
    private func publish(_ event: SyncEvent) {
        Log.session.debug("\(event.logDescription)")

        eventsPublisher.send(event)

        DispatchQueue.main.async {
            switch event {
            case let .workSuccess(.fetch(operation), .fetch(response)):
                self.fetchWorkCompletedSubject.send((operation, response))
            case let .workSuccess(.modify(operation), .modify(response)):
                self.modifyWorkCompletedSubject.send((operation, response))
            case let .halt(error):
                self.haltedSubject.send(error)
            case let .accountStatusChanged(status):
                self.accountStatusSubject.send(status)
            case .start:
                self.haltedSubject.send(nil)
            default:
                break
            }
        }
    }

    // MARK: Test support

    /// Whether the session has nothing under way: no run loop and no account status lookup. It stays
    /// that way until one of its methods is called.
    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }

        return runLoopTask == nil && !isLookingUpAccountStatus
    }

    /// Returns once every change made so far has been handed to observers. Events for the subjects
    /// that deliver on the main queue are by then queued there.
    func flushOutput() {
        outputQueue.sync {}
    }
}
