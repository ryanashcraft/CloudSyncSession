import CloudKit
import Combine

public typealias ConflictResolver = (CKRecord, CKRecord) -> CKRecord?
public typealias ChangeTokenExpiredResolver = () -> CKServerChangeToken?

public struct StopError: Error {}

/// An object that manages a long-lived series of CloudKit syncing operations.
public class CloudSyncSession {
    /// Represents the state of the session.
    @Published public var state = SyncState()

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

    private var dispatchQueue = DispatchQueue(label: "CloudSyncSession.Dispatch", qos: .userInitiated)

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

    /// Add an additional mdidleware at the end of the chain.
    public func appendMiddleware<M: Middleware>(_ middleware: M) {
        middlewares.append(middleware.eraseToAnyMiddleware())
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
    public func reset() {
        state = SyncState()
    }

    /// Queue a fetch operation.
    public func fetch(_ operation: FetchOperation) {
        guard state.fetchQueue.allSatisfy({ $0.changeToken != operation.changeToken }) else {
            return
        }

        dispatch(event: .doWork(.fetch(operation)))
    }

    /// Queue a modify operation.
    public func modify(_ operation: ModifyOperation) {
        dispatch(event: .doWork(.modify(operation)))
    }

    func dispatch(event: SyncEvent) {
        dispatchQueue.async {
            func next(event: SyncEvent, middlewaresToRun: [AnyMiddleware]) -> SyncEvent {
                self.eventsPublisher.send(event)

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
