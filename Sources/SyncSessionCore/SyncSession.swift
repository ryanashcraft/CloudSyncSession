import Combine
import Foundation

/// An object that manages a long-lived series of syncing operations against one backend.
///
/// The session keeps queues of work (setup, modify, fetch) in its `state`. Every method here
/// changes that state in one step, under a lock, on the caller's thread. A single task, the run
/// loop in `SyncSession+RunLoop.swift`, then carries out the work at the head of the queue, one
/// piece at a time.
///
/// The session knows nothing about any particular server. A backend's library subclasses it and
/// supplies two functions: one that carries out a piece of work, and one that decides what to do
/// about a failure.
///
/// All mutable state is guarded by `lock`, which is what makes the type safe to share across threads.
open class SyncSession<Backend: SyncBackend>: @unchecked Sendable {
    public typealias State = SessionState<Backend>
    public typealias Event = SessionEvent<Backend>
    public typealias Work = SessionWork<Backend>

    /// Carries out one piece of work against the server and reports how it went.
    ///
    /// The session hands over one piece of work at a time and waits for the function to return
    /// before it does anything else. When the session is stopped or reset it cancels the task the
    /// function is running in. The function should then give up work it has not sent yet and
    /// return without delay, but it must not return while a request it has sent could still reach
    /// the server. What a cancelled call reports as a failure is not acted on.
    public typealias Perform = (Work) async -> Result<Work.Result, Error>

    /// Decides what to do about work that failed.
    public typealias ResolveFailure = (Error, Work) -> FailureResolution<Backend>

    /// Looks up the current account status. The session calls it from `start()` whenever it does
    /// not know the status, which is the case for a new session and after `reset()`.
    public typealias AccountStatusProvider = @Sendable () async -> Backend.AccountStatus

    /// Represents the state of the session.
    public var state: State {
        lock.lock()
        defer { lock.unlock() }

        return lockedState
    }

    /// A Combine publisher that publishes the state, starting with the current value.
    public var statePublisher: AnyPublisher<State, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    /// A Combine subject that publishes the most recent event.
    public let eventsPublisher = CurrentValueSubject<Event?, Never>(nil)

    /// A Combine subject that publishes fetch work that has completed.
    public let fetchWorkCompletedSubject = PassthroughSubject<(SessionFetchOperation<Backend>, SessionFetchOperation<Backend>.Response), Never>()

    /// A Combine subject that publishes modify work that has completed.
    public let modifyWorkCompletedSubject = PassthroughSubject<(SessionModifyOperation<Backend>, SessionModifyOperation<Backend>.Response), Never>()

    /// A Combine subject that signals when the session has halted due to an error.
    public let haltedSubject = CurrentValueSubject<Error?, Never>(nil)

    /// A Combine subject that publishes the latest account status.
    public let accountStatusSubject = CurrentValueSubject<Backend.AccountStatus?, Never>(nil)

    let performWork: Perform
    let resolveFailure: ResolveFailure
    let accountStatusProvider: AccountStatusProvider?
    let pacing: Pacing

    /// Guards `lockedState`, `runLoopTask`, `cancelCurrentStep`, `workInFlight`, `observers`, and
    /// `isLookingUpAccountStatus`.
    let lock = NSLock()
    var lockedState = State()
    var runLoopTask: Task<Void, Never>?

    /// Cancels what the run loop is waiting on right now: a wait of its own, or an operation that
    /// is being carried out. Nil when it is waiting on neither.
    var cancelCurrentStep: (@Sendable () -> Void)?

    /// The work the backend has been handed, until the change that records how it ended.
    var workInFlight: Work?

    /// The open async streams and the `perform` calls that are waiting.
    var observers = SessionObservers<Backend>()

    private var isLookingUpAccountStatus = false

    private let stateSubject = CurrentValueSubject<State, Never>(State())

    /// Delivers events and state to observers in the order the changes were made, without holding the lock.
    private let outputQueue = DispatchQueue(label: "SyncSession.Output", qos: .userInitiated)

    /**
     Creates a session.

     - Parameter perform: Carries out one piece of work against the server.
     - Parameter resolveFailure: Decides what to do about work that failed.
     - Parameter accountStatusProvider: Looks up the account status. Called from `start()` whenever the status is not known. Without one, `accountStatusChanged(_:)` must be called before any work can run.
     - Parameter pacing: How the session waits. Tests pass their own so that they do not wait in real time.
     */
    public init(
        perform: @escaping Perform,
        resolveFailure: @escaping ResolveFailure,
        accountStatusProvider: AccountStatusProvider? = nil,
        pacing: Pacing = .live
    ) {
        performWork = perform
        self.resolveFailure = resolveFailure
        self.accountStatusProvider = accountStatusProvider
        self.pacing = pacing
    }

    deinit {
        observers.finishStreams()
    }

    // MARK: Lifecycle

    /// Start the session, or resume it after it halted. Queued work is kept across a halt.
    public func start() {
        let shouldLookUpAccountStatus: Bool = update { change in
            change.emit(.start)
            change.state.isHalted = false

            for step in Backend.setupSteps where change.state.setupResults[step] == nil && !change.state.hasQueuedSetup(of: step) {
                let work = Work.setup(SessionSetupOperation(step: step))

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
    /// work is kept for the next `start()`. An operation that is being carried out is cancelled.
    /// What that does is up to the backend: it should drop a request it has not sent yet and let
    /// one the server already has finish. If the operation succeeds, that is reported. Otherwise
    /// its work stays queued.
    ///
    /// This returns immediately, before that operation has wound down. Use `stopAndWait()` when
    /// what comes next must not overlap with it.
    public func stop() {
        _ = halt()
    }

    /// Stops the session as `stop()` does, then waits until the operation that was being carried
    /// out, if there was one, has finished or been cancelled.
    ///
    /// Use this before anything destructive, such as deleting everything on the server. After it
    /// returns, nothing this session sent before the call can still reach the server.
    ///
    /// The wait lasts as long as the backend takes to wind down the one cancelled operation: no
    /// time for a request it had not sent yet, and the rest of the round trip for one it had.
    ///
    /// If `start()` is called before this returns, it returns once the session next runs out of work.
    public func stopAndWait() async {
        await halt()?.value
    }

    /// Reset the session state. Queued work is discarded. An operation that is being carried out
    /// is cancelled, and its result is ignored if one still arrives.
    public func reset() {
        update { change in
            cancelCurrentStep?()
            change.state = State()
            change.interruption = .reset
        }
    }

    /// Tell the session the account status. No work is sent until the account is available.
    public func accountStatusChanged(_ status: Backend.AccountStatus) {
        accountStatusChanged(status, finishesLookup: false)
    }

    // MARK: Work

    /// Queue a fetch operation. A fetch from a change token that is already queued is ignored.
    public func fetch(_ operation: SessionFetchOperation<Backend>) {
        update { change in
            guard !change.state.hasQueuedFetch(from: operation.changeToken) else {
                change.state.noteFetchAlsoQueued(from: operation.changeToken)

                return
            }

            let work = Work.fetch(operation)

            change.emit(.doWork(work))
            change.state.enqueue(work)
        }
    }

    /// Queue a modify operation. An operation with more records than fit in one request is queued as
    /// several, in order, with nothing else in between.
    public func modify(_ operation: SessionModifyOperation<Backend>) {
        update { change in
            for piece in operation.shouldSplit ? operation.split : [operation] {
                let work = Work.modify(piece)

                change.emit(.doWork(work))
                change.state.enqueue(work)
            }
        }
    }

    // MARK: State changes

    /// A change to the session being made under the lock: the state to store and the events to announce.
    struct Change {
        var state: State
        fileprivate(set) var events: [Event] = []

        /// Set when the change stops or resets the session, for the `perform` calls it ends.
        var interruption: SessionInterruption?

        mutating func emit(_ event: Event) {
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

        var change = Change(state: lockedState)
        let value = body(&change)

        let nextWorkID = change.state.currentWork?.id

        observers.announce(change.events, state: &change.state, interruption: change.interruption, workInFlight: workInFlight)

        // The run loop may be in a wait for work that was just withdrawn. Cut it short so that
        // the work behind it does not sit out a backoff that is no longer anyone's.
        if workInFlight == nil, change.state.currentWork?.id != nextWorkID {
            cancelCurrentStep?()
        }

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

        let resumptions = observers.takeResumptions()

        lock.unlock()

        for resume in resumptions {
            resume()
        }

        return value
    }

    private func halt() -> Task<Void, Never>? {
        update { change in
            change.emit(.halt(Backend.makeStopError()))
            change.state.isHalted = true
            change.interruption = .stopped

            cancelCurrentStep?()

            return runLoopTask
        }
    }

    private func accountStatusChanged(_ status: Backend.AccountStatus, finishesLookup: Bool) {
        update { change in
            if finishesLookup {
                isLookingUpAccountStatus = false
            }

            change.emit(.accountStatusChanged(status))
            change.state.hasGoodAccountStatus = Backend.isAvailable(status)
            change.state.updateOperationMode()
        }
    }

    /// Announces one event: logs it, sends it to `eventsPublisher`, and forwards it to whichever
    /// of the other subjects reports that kind of event. Runs on the output queue.
    private func publish(_ event: Event) {
        Log<Backend>.session.debug("\(event.logDescription)")

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

    /// How many async streams are open.
    var observerCount: Int {
        lock.lock()
        defer { lock.unlock() }

        return observers.streamCount
    }

    /// Returns once every change made so far has been handed to observers. Events for the subjects
    /// that deliver on the main queue are by then queued there.
    func flushOutput() {
        outputQueue.sync {}
    }
}
