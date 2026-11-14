import Foundation

/// Why a `perform` call ended without a response.
public enum SessionInterruption: Error {
    /// The session halted on this error.
    case halted(Error)

    /// `stop()` or `stopAndWait()` was called.
    case stopped

    /// `reset()` was called.
    case reset
}

/// Thrown by `perform` for a fetch when a fetch from the same change token is already queued.
public struct DuplicateFetchError: Error {
    public init() {}
}

// MARK: Streams

/// The session as async sequences. Each property makes a new stream on every access, and each
/// stream gets every element on its own. A stream ends when the session is deallocated.
///
/// Elements are buffered until they are read. Apart from `states`, nothing is dropped, so a stream
/// that is kept but not read grows.
public extension SyncSession {
    /// Every event from the moment the stream is made, in order. Nothing is replayed.
    var events: AsyncStream<Event> {
        makeStream { observers, id, continuation, _ in
            observers.events[id] = continuation
        }
    }

    /// Every fetch that completes after the stream is made, one element per page. That includes
    /// the pages the session fetches by itself after a page that reports more.
    var fetchCompletions: AsyncStream<(SessionFetchOperation<Backend>, SessionFetchOperation<Backend>.Response)> {
        makeStream { observers, id, continuation, _ in
            observers.fetchCompletions[id] = continuation
        }
    }

    /// Every modify request that completes after the stream is made. An operation that was sent
    /// in several pieces completes once per piece.
    var modifyCompletions: AsyncStream<(SessionModifyOperation<Backend>, SessionModifyOperation<Backend>.Response)> {
        makeStream { observers, id, continuation, _ in
            observers.modifyCompletions[id] = continuation
        }
    }

    /// The error the session is halted on, or nil while it is not halted. The first element is
    /// the current value. After it comes every change, in order: the error on each halt, and nil
    /// when `start()` or `reset()` ends one. `stop()` reports the backend's stop error.
    var halts: AsyncStream<Error?> {
        makeStream { observers, id, continuation, _ in
            observers.halts[id] = continuation
            continuation.yield(observers.currentHalt?.error)
        }
    }

    /// The session's state. The first element is the current state. After it come changes, but
    /// only the newest one that has not been read is kept, so a slow reader skips states and
    /// never falls behind. Use `events` to see every step.
    var states: AsyncStream<State> {
        makeStream(bufferingPolicy: .bufferingNewest(1)) { observers, id, continuation, state in
            observers.states[id] = continuation
            continuation.yield(Unchecked(value: state).value)
        }
    }

    private func makeStream<Element>(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded,
        _ subscribe: (inout SessionObservers<Backend>, UUID, AsyncStream<Element>.Continuation, State) -> Void
    ) -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: bufferingPolicy)

        // Off the calling thread, because nothing promises that thread is not inside the session.
        continuation.onTermination = { [weak self] _ in
            let session = self

            DispatchQueue.global(qos: .utility).async {
                session?.removeSubscriber(id)
            }
        }

        lock.lock()
        defer { lock.unlock() }

        subscribe(&observers, id, continuation, lockedState)

        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        observers.removeSubscriber(id)
    }
}

// MARK: Awaitable work

/// A `perform` call queues an operation and waits for it. The operation is the call's own: it is
/// in the session's queue only while the call waits. When the call throws, whatever part of the
/// operation has not been sent is taken out of the queue, so nothing it queued is sent later.
/// The one thing that cannot be taken back is a request the backend already has.
///
/// Both calls throw:
/// - `SessionInterruption.halted` when the session halts, for this work's failure or any other.
///   On a session that is already halted the call throws at once and queues nothing.
/// - `SessionInterruption.stopped` when the session is stopped. If the call's own request is
///   with the backend at that moment, the call first waits for it: it returns normally if the
///   request succeeded and that finished the operation, and throws otherwise.
/// - `SessionInterruption.reset` when the session is reset.
/// - `CancellationError` when the calling task is cancelled. A request the backend already has
///   is left to finish, and is reported on the streams.
///
/// A session that is not ready yet, because it has no account status or is still setting up, is
/// not an error. The call waits, as queued work does.
///
/// Work a `perform` call completes is reported everywhere else as usual: on the completion
/// streams, the Combine subjects and `events`.
public extension SyncSession {
    /// Queues a fetch and returns its page.
    ///
    /// When the page reports more, the session fetches the next page by itself, as it does for
    /// `fetch(_:)`. That page is reported on `fetchCompletions`, not by this call.
    ///
    /// Throws `DuplicateFetchError`, and queues nothing, when a fetch from the same change token
    /// is already queued. `fetch(_:)` ignores that fetch silently.
    func perform(_ operation: SessionFetchOperation<Backend>) async throws -> SessionFetchOperation<Backend>.Response {
        let performID = UUID()
        var owned = operation

        owned.performID = performID

        let work = [Work.fetch(owned)]

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(.fetch(continuation), performID: performID, queueing: work) { state in
                    state.hasQueuedFetch(from: operation.changeToken) ? DuplicateFetchError() : nil
                }
            }
        } onCancel: {
            self.cancelPerform(performID)
        }
    }

    /// Queues a modify and returns once all of it is on the server.
    ///
    /// The session may send the operation in several pieces: it splits one that is too large, and
    /// it sends a request again with different records after resolving a conflict. The response
    /// is for the whole operation. It holds what every piece saved and deleted, in the order the
    /// pieces completed.
    func perform(_ operation: SessionModifyOperation<Backend>) async throws -> SessionModifyOperation<Backend>.Response {
        let performID = UUID()
        var owned = operation

        owned.performID = performID

        let work = (owned.shouldSplit ? owned.split : [owned]).map(Work.modify)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(.modify(continuation, savedRecords: [], deletedRecordIDs: []), performID: performID, queueing: work) { _ in
                    nil
                }
            }
        } onCancel: {
            self.cancelPerform(performID)
        }
    }

    /// Registers a waiter and queues its work in one change, or ends the waiter without queueing.
    private func begin(
        _ waiter: SessionObservers<Backend>.Waiter,
        performID: UUID,
        queueing work: [Work],
        refusal: (State) -> Error?
    ) {
        update { change in
            // Checked under the lock. A cancellation that comes later finds the waiter registered.
            if Task.isCancelled {
                observers.reject(waiter, with: CancellationError())
            } else if let halt = observers.currentHalt, change.state.isHalted {
                observers.reject(waiter, with: halt.interruption)
            } else if let error = refusal(change.state) {
                observers.reject(waiter, with: error)
            } else {
                observers.addWaiter(waiter, performID: performID)

                for piece in work {
                    change.emit(.doWork(piece))
                    change.state.enqueue(piece)
                }
            }
        }
    }

    private func cancelPerform(_ performID: UUID) {
        update { _ in
            observers.failWaiter(performID: performID, with: CancellationError())
        }
    }
}
