import Foundation

/// Who is watching a session through its async surface: the open streams, and the `perform`
/// calls that are waiting for their work.
///
/// A value of this type has no lock of its own. The session keeps one and touches it only while
/// holding the session's lock, which is also what puts stream elements in the order the changes
/// were made.
struct SessionObservers<Backend: SyncBackend> {
    typealias FetchCompletion = (SessionFetchOperation<Backend>, SessionFetchOperation<Backend>.Response)
    typealias ModifyCompletion = (SessionModifyOperation<Backend>, SessionModifyOperation<Backend>.Response)

    /// A `perform` call that has not returned yet.
    enum Waiter {
        case fetch(CheckedContinuation<SessionFetchOperation<Backend>.Response, Error>)

        /// Holds what the pieces completed so far reported.
        case modify(
            CheckedContinuation<SessionModifyOperation<Backend>.Response, Error>,
            savedRecords: [Backend.Record],
            deletedRecordIDs: [Backend.RecordID]
        )

        fileprivate func fail(with error: Error) {
            switch self {
            case let .fetch(continuation):
                continuation.resume(throwing: error)
            case let .modify(continuation, _, _):
                continuation.resume(throwing: error)
            }
        }
    }

    var events = [UUID: AsyncStream<SessionEvent<Backend>>.Continuation]()
    var fetchCompletions = [UUID: AsyncStream<FetchCompletion>.Continuation]()
    var modifyCompletions = [UUID: AsyncStream<ModifyCompletion>.Continuation]()
    var halts = [UUID: AsyncStream<Error?>.Continuation]()
    var states = [UUID: AsyncStream<SessionState<Backend>>.Continuation]()

    /// The waiting `perform` calls, by the ID their work carries.
    private(set) var waiters = [UUID: Waiter]()

    /// What the session is halted on, and what a `perform` throws because of it. Nil while the
    /// session is not halted.
    private(set) var currentHalt: (error: Error, interruption: SessionInterruption)?

    /// What it takes to wake the `perform` calls that have ended.
    ///
    /// A call is never woken while the session's lock is held. Its cancellation handler takes that
    /// lock, and runs while the Swift runtime holds a lock on the call's task. Waking the task
    /// needs the runtime's lock, so doing it under the session's would let the two wait on each
    /// other for good. The session takes these after each change and runs them once it has let
    /// go of its lock.
    private var resumptions = [() -> Void]()

    // MARK: Waiters

    mutating func addWaiter(_ waiter: Waiter, performID: UUID) {
        waiters[performID] = waiter
    }

    /// Ends a `perform` call by throwing. Does nothing if the call has already ended.
    mutating func failWaiter(performID: UUID, with error: Error) {
        if let waiter = waiters.removeValue(forKey: performID) {
            reject(waiter, with: error)
        }
    }

    /// Ends a `perform` call that was never registered by throwing.
    mutating func reject(_ waiter: Waiter, with error: Error) {
        resumptions.append {
            waiter.fail(with: error)
        }
    }

    mutating func takeResumptions() -> [() -> Void] {
        defer { resumptions = [] }

        return resumptions
    }

    // MARK: Changes

    /// Tells streams and waiters about one change to the session, and takes out of the queues
    /// any work whose `perform` call is no longer waiting for it.
    ///
    /// - Parameter state: The state the change leaves. Withdrawn work is removed from it.
    /// - Parameter interruption: Set when the change halted, stopped or reset the session.
    /// - Parameter workInFlight: The work the backend has right now, if any.
    mutating func announce(
        _ announcedEvents: [SessionEvent<Backend>],
        state: inout SessionState<Backend>,
        interruption: SessionInterruption?,
        workInFlight: SessionWork<Backend>?
    ) {
        for event in announcedEvents {
            for continuation in events.values {
                continuation.yield(event)
            }

            switch event {
            case let .workSuccess(.fetch(operation), .fetch(response)):
                for continuation in fetchCompletions.values {
                    continuation.yield((operation, response))
                }

                if let performID = operation.performID, case let .fetch(continuation) = waiters[performID] {
                    waiters[performID] = nil
                    resumptions.append {
                        continuation.resume(returning: response)
                    }
                }
            case let .workSuccess(.modify(operation), .modify(response)):
                for continuation in modifyCompletions.values {
                    continuation.yield((operation, response))
                }

                if let performID = operation.performID, case let .modify(continuation, savedRecords, deletedRecordIDs) = waiters[performID] {
                    let savedRecords = savedRecords + response.savedRecords
                    let deletedRecordIDs = deletedRecordIDs + response.deletedRecordIDs

                    if state.hasWork(performID: performID) {
                        waiters[performID] = .modify(continuation, savedRecords: savedRecords, deletedRecordIDs: deletedRecordIDs)
                    } else {
                        waiters[performID] = nil
                        let combined = SessionModifyOperation<Backend>.Response(savedRecords: savedRecords, deletedRecordIDs: deletedRecordIDs)

                        resumptions.append {
                            continuation.resume(returning: combined)
                        }
                    }
                }
            case let .halt(error):
                currentHalt = (error, interruption ?? .halted(error))

                for continuation in halts.values {
                    continuation.yield(error)
                }
            case .start:
                clearHalt()
            default:
                break
            }
        }

        if case .reset = interruption {
            clearHalt()

            for performID in waiters.keys {
                failWaiter(performID: performID, with: SessionInterruption.reset)
            }
        }

        // A halted session sends nothing, so a call waiting on it would wait until some later
        // start. The one exception is a call whose request the backend still has: it is settled
        // by the change that reports how that request ended.
        if state.isHalted, let currentHalt {
            for performID in waiters.keys where performID != workInFlight?.performID {
                failWaiter(performID: performID, with: currentHalt.interruption)
            }
        }

        for performID in state.queuedPerformIDs where waiters[performID] == nil {
            state.withdrawWork(performID: performID, except: workInFlight?.id)
        }

        for continuation in states.values {
            continuation.yield(state)
        }
    }

    var streamCount: Int {
        events.count + fetchCompletions.count + modifyCompletions.count + halts.count + states.count
    }

    func finishStreams() {
        events.values.forEach { $0.finish() }
        fetchCompletions.values.forEach { $0.finish() }
        modifyCompletions.values.forEach { $0.finish() }
        halts.values.forEach { $0.finish() }
        states.values.forEach { $0.finish() }
    }

    mutating func removeSubscriber(_ id: UUID) {
        events[id] = nil
        fetchCompletions[id] = nil
        modifyCompletions[id] = nil
        halts[id] = nil
        states[id] = nil
    }

    private mutating func clearHalt() {
        guard currentHalt != nil else {
            return
        }

        currentHalt = nil

        for continuation in halts.values {
            continuation.yield(nil)
        }
    }
}
