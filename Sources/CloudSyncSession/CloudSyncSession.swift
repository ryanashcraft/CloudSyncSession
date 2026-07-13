import CloudKit
import Combine

public typealias ConflictResolver = (CKRecord, CKRecord) -> CKRecord?
public typealias ChangeTokenExpiredResolver = () -> CKServerChangeToken?

public struct StopError: Error {}

/// An object that manages a long-lived series of CloudKit syncing operations.
public class CloudSyncSession {
    /// Represents the state of the session.
    @Published public var state = SyncState() {
        didSet {
            statesBroadcast.send(state)
        }
    }

    /// Handles fetch, modify, create zone, and create subscription operations.
    let operationHandler: OperationHandler

    /// The CloudKit zone ID.
    let zoneID: CKRecordZone.ID

    /// The function handler that will be called to resolve record conflicts.
    public let resolveConflict: ConflictResolver?

    /// The function handler that will be called when the change token should be expired.
    public let resolveExpiredChangeToken: ChangeTokenExpiredResolver?

    /// The ordered chain of middleware that will transform events and/or trigger side effects.
    private var middlewares = [AnyMiddleware]()

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

    /// Backs ``events``. Fed at every dispatch recursion level, adjacent to
    /// eventsPublisher, so the async surface observes exactly what the Combine
    /// surface observes.
    let eventsBroadcast = AsyncBroadcast<SyncEvent>(replaysLatest: false, bufferingPolicy: .unbounded)

    /// Backs ``fetchWorkCompletions``. Lossless: completions become ingested
    /// records downstream, so no element may be dropped.
    let fetchWorkCompletionsBroadcast = AsyncBroadcast<(FetchOperation, FetchOperation.Response)>(replaysLatest: false, bufferingPolicy: .unbounded)

    /// Backs ``modifyWorkCompletions``. Lossless, same contract as fetch.
    let modifyWorkCompletionsBroadcast = AsyncBroadcast<(ModifyOperation, ModifyOperation.Response)>(replaysLatest: false, bufferingPolicy: .unbounded)

    /// Backs ``haltedErrors``. State: replays the current value, nil meaning
    /// not halted, mirroring haltedSubject.
    let haltedErrorsBroadcast = AsyncBroadcast<Error?>(replaysLatest: true, bufferingPolicy: .bufferingNewest(1), initialElement: .some(nil))

    /// Backs ``accountStatuses``. State: replays the latest known status.
    let accountStatusesBroadcast = AsyncBroadcast<CKAccountStatus?>(replaysLatest: true, bufferingPolicy: .bufferingNewest(1), initialElement: .some(nil))

    /// Backs ``states``. State: replays the current session state.
    let statesBroadcast = AsyncBroadcast<SyncState>(replaysLatest: true, bufferingPolicy: .bufferingNewest(1), initialElement: SyncState())

    /// One-shot waiters for the async perform APIs. Resolved by
    /// SubjectMiddleware, where events are fully transformed.
    let workWaiters = WorkWaiters()

    let dispatchQueue = DispatchQueue(label: "CloudSyncSession.Dispatch", qos: .userInitiated)

    /**
     Creates a session.

     - Parameter operationHandler: The object that handles fetch, modify, create zone, and create subscription operations.
     - Parameter zoneID: The CloudKit zone ID.
     - Parameter resolveConflict: The function handler that will be called to resolve record conflicts.
     - Parameter resolveExpiredChangeToken: The function handler that will be called when the change token should be expired.
     */
    public init(
        operationHandler: OperationHandler,
        zoneID: CKRecordZone.ID,
        resolveConflict: @escaping ConflictResolver,
        resolveExpiredChangeToken: @escaping ChangeTokenExpiredResolver
    ) {
        self.operationHandler = operationHandler
        self.zoneID = zoneID
        self.resolveConflict = resolveConflict
        self.resolveExpiredChangeToken = resolveExpiredChangeToken

        middlewares = [
            SplittingMiddleware(session: self).eraseToAnyMiddleware(),
            ErrorMiddleware(session: self).eraseToAnyMiddleware(),
            RetryMiddleware(session: self).eraseToAnyMiddleware(),
            WorkMiddleware(session: self).eraseToAnyMiddleware(),
            SubjectMiddleware(session: self).eraseToAnyMiddleware(),
            LoggerMiddleware(session: self).eraseToAnyMiddleware(),
            ZoneMiddleware(session: self).eraseToAnyMiddleware(),
        ]
    }

    /// Add an additional middleware at the end of the chain.
    public func appendMiddleware<M: Middleware>(_ middleware: M) {
        let anyMiddleware = middleware.eraseToAnyMiddleware()

        dispatchQueue.async {
            self.middlewares.append(anyMiddleware)
        }
    }

    /// Start the session.
    public func start() {
        dispatch(event: .start)
    }

    /// Stop/halt the session.
    public func stop() {
        dispatch(event: .halt(StopError()))
    }

    /// Reset the session state.
    ///
    /// The reset runs synchronously on the session's dispatch queue: it is
    /// ordered after any events already dispatched and completes before the
    /// method returns, so callers can stamp state or call start() immediately
    /// afterwards without the reset clobbering them. Must not be called from
    /// the session's own dispatch queue. Pending perform(_:) waiters are not
    /// resolved by a reset; they remain registered until their work completes
    /// or the session halts.
    public func reset() {
        dispatchQueue.sync {
            self.state = SyncState()
        }
    }

    /// Queue a fetch operation.
    ///
    /// The duplicate change token check runs on the dispatch queue, where state
    /// is confined.
    public func fetch(_ operation: FetchOperation) {
        dispatchQueue.async {
            guard self.state.fetchQueue.allSatisfy({ $0.changeToken != operation.changeToken }) else {
                return
            }

            self.dispatch(event: .doWork(.fetch(operation)))
        }
    }

    /// Queue a modify operation.
    public func modify(_ operation: ModifyOperation) {
        dispatch(event: .doWork(.modify(operation)))
    }

    func dispatch(event: SyncEvent) {
        dispatchQueue.async {
            func next(event: SyncEvent, middlewaresToRun: [AnyMiddleware]) -> SyncEvent {
                self.eventsPublisher.send(event)
                self.eventsBroadcast.send(event)

                if let middleware = middlewaresToRun.last {
                    return middleware.run(
                        next: { event in
                            next(event: event, middlewaresToRun: middlewaresToRun.dropLast())
                        },
                        event: event
                    )
                } else {
                    self.state = self.state.reduce(event: event)

                    return event
                }
            }

            _ = next(event: event, middlewaresToRun: Array(self.middlewares.reversed()))
        }
    }
}

// The session is used from multiple threads by design. The library's own
// writes to mutable state are confined to dispatchQueue; the broadcasts and
// waiters lock internally; the Combine subjects are thread safe. One known
// gap: the public `state` setter is technically writable cross-thread by
// clients, outside the queue confinement. Closing it (a queued stamping API
// or private(set)) is a breaking change reserved for a future internals pass.
extension CloudSyncSession: @unchecked Sendable {}
