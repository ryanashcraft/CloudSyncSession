import CloudKit
import Foundation

public extension CloudSyncSession {
    /// An async counterpart to ``eventsPublisher``.
    ///
    /// Lossless from stream creation, never replays. Like eventsPublisher, an
    /// event is observed once per middleware recursion level, so a single
    /// dispatched event appears several times, including transformed variants.
    /// Match on what you need rather than counting elements.
    var events: AsyncStream<SyncEvent> {
        eventsBroadcast.makeStream()
    }

    /// An async counterpart to ``fetchWorkCompletedSubject``.
    ///
    /// Lossless from stream creation: create the stream before dispatching
    /// work and it observes every completion that follows. Elements buffer
    /// until iterated, so consume promptly.
    var fetchWorkCompletions: AsyncStream<(FetchOperation, FetchOperation.Response)> {
        fetchWorkCompletionsBroadcast.makeStream()
    }

    /// An async counterpart to ``modifyWorkCompletedSubject``.
    ///
    /// Lossless from stream creation, same contract as ``fetchWorkCompletions``.
    var modifyWorkCompletions: AsyncStream<(ModifyOperation, ModifyOperation.Response)> {
        modifyWorkCompletionsBroadcast.makeStream()
    }

    /// An async counterpart to ``haltedSubject``.
    ///
    /// State surface: the first element is the current value (nil when the
    /// session is not halted), followed by changes, buffering only the newest.
    var haltedErrors: AsyncStream<Error?> {
        haltedErrorsBroadcast.makeStream()
    }

    /// An async counterpart to ``accountStatusSubject``.
    ///
    /// State surface: replays the latest known status, then changes.
    var accountStatuses: AsyncStream<CKAccountStatus?> {
        accountStatusesBroadcast.makeStream()
    }

    /// An async counterpart to the published ``state``.
    ///
    /// State surface: the first element is the current state, followed by
    /// every state change, buffering only the newest.
    var states: AsyncStream<SyncState> {
        statesBroadcast.makeStream()
    }

    /// Dispatches a fetch operation and awaits its completion.
    ///
    /// Correlates by operation identity, which survives retries. Throws the
    /// work failure if the fetch fails terminally, the halt error if the
    /// session halts first (including StopError from ``stop()``),
    /// DuplicateFetchOperationError if a fetch with the same change token is
    /// already queued, and CancellationError if the awaiting task is
    /// cancelled. On an already-halted session the halt error is thrown
    /// immediately and the operation is never queued. Cancelling the await
    /// abandons the wait; it does not cancel the underlying work.
    func perform(_ operation: FetchOperation) async throws -> FetchOperation.Response {
        let operationID = operation.id

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                dispatchQueue.async {
                    guard self.state.fetchQueue.allSatisfy({ $0.changeToken != operation.changeToken }) else {
                        continuation.resume(throwing: DuplicateFetchOperationError())

                        return
                    }

                    if self.workWaiters.addFetchWaiter(operationID: operationID, continuation: continuation) {
                        self.dispatch(event: .doWork(.fetch(operation)))
                    }
                }
            }
        } onCancel: {
            workWaiters.cancelWaiter(id: operationID)
        }
    }

    /// Dispatches a modify operation and awaits its completion.
    ///
    /// Correlates by checkpointID, the only identity that survives splitting
    /// (the checkpoint rides the final chunk) and conflict resolution (a
    /// requeued operation gets a new id but keeps the checkpoint). The
    /// returned response belongs to the checkpoint carrying chunk. Throws
    /// like perform(FetchOperation), and likewise never queues the operation
    /// on an already-halted session. A nil checkpointID is a programmer
    /// error and traps.
    func perform(_ operation: ModifyOperation) async throws -> ModifyOperation.Response {
        guard let checkpointID = operation.checkpointID else {
            preconditionFailure("perform(_:) requires a ModifyOperation with a checkpointID; the checkpoint is the only identity that survives splitting and conflict resolution")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                dispatchQueue.async {
                    if self.workWaiters.addModifyWaiter(checkpointID: checkpointID, continuation: continuation) {
                        self.dispatch(event: .doWork(.modify(operation)))
                    }
                }
            }
        } onCancel: {
            workWaiters.cancelWaiter(id: checkpointID)
        }
    }

    /// Awaits the first fetch completion matching the predicate.
    ///
    /// Registers before returning control, so a completion arriving
    /// immediately after the call cannot be missed. Throws the halt error if
    /// the session halts first (including StopError), and CancellationError
    /// if the awaiting task is cancelled.
    func firstFetchCompletion(
        where predicate: @escaping @Sendable (FetchOperation, FetchOperation.Response) -> Bool
    ) async throws -> (FetchOperation, FetchOperation.Response) {
        let waiterID = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                workWaiters.addFetchCompletionWaiter(id: waiterID, predicate: predicate, continuation: continuation)
            }
        } onCancel: {
            workWaiters.cancelWaiter(id: waiterID)
        }
    }
}
