import Foundation

/// Thrown by perform(_:) when a fetch operation is dropped because another
/// fetch with the same change token is already queued. Mirrors the silent
/// drop in fetch(_:), made explicit because an awaiting caller would
/// otherwise hang.
public struct DuplicateFetchOperationError: Error {
    public init() {}
}

/// One-shot waiters for perform(_:) and firstFetchCompletion(where:).
///
/// Resolution happens at the SubjectMiddleware level. By the time an event
/// reaches that middleware, the error and retry middleware have already
/// transformed recoverable failures into retry, split, or conflict events,
/// so a workFailure observed here is terminal.
///
/// The halt error is cached under the same lock that guards registration, so
/// a waiter can never register into the gap between halt resolution and the
/// cache update: registration either observes the cached error and fails
/// immediately, or lands before resolution and is failed by it.
final class WorkWaiters: @unchecked Sendable {
    private let lock = NSLock()
    private var haltError: Error?
    private var fetchContinuationsByOperationID: [UUID: [CheckedContinuation<FetchOperation.Response, any Error>]] = [:]
    private var modifyContinuationsByCheckpointID: [UUID: [CheckedContinuation<ModifyOperation.Response, any Error>]] = [:]
    private var fetchCompletionWaitersByID: [UUID: (predicate: (FetchOperation, FetchOperation.Response) -> Bool, continuation: CheckedContinuation<(FetchOperation, FetchOperation.Response), any Error>)] = [:]

    /// IDs cancelled before their waiter registered. A registration that
    /// finds its ID here resumes as cancelled immediately. A cancellation
    /// that arrives after normal resolution leaves a tombstone; IDs are
    /// never reused, so the only cost is a few bytes per occurrence.
    private var cancelledWaiterIDs: Set<UUID> = []

    func addFetchWaiter(operationID: UUID, continuation: CheckedContinuation<FetchOperation.Response, any Error>) {
        lock.lock()

        if cancelledWaiterIDs.contains(operationID) {
            cancelledWaiterIDs.remove(operationID)
            lock.unlock()
            continuation.resume(throwing: CancellationError())

            return
        }

        if let haltError {
            lock.unlock()
            continuation.resume(throwing: haltError)

            return
        }

        fetchContinuationsByOperationID[operationID, default: []].append(continuation)
        lock.unlock()
    }

    func addModifyWaiter(checkpointID: UUID, continuation: CheckedContinuation<ModifyOperation.Response, any Error>) {
        lock.lock()

        if cancelledWaiterIDs.contains(checkpointID) {
            cancelledWaiterIDs.remove(checkpointID)
            lock.unlock()
            continuation.resume(throwing: CancellationError())

            return
        }

        if let haltError {
            lock.unlock()
            continuation.resume(throwing: haltError)

            return
        }

        modifyContinuationsByCheckpointID[checkpointID, default: []].append(continuation)
        lock.unlock()
    }

    func addFetchCompletionWaiter(
        id: UUID,
        predicate: @escaping (FetchOperation, FetchOperation.Response) -> Bool,
        continuation: CheckedContinuation<(FetchOperation, FetchOperation.Response), any Error>
    ) {
        lock.lock()

        if cancelledWaiterIDs.contains(id) {
            cancelledWaiterIDs.remove(id)
            lock.unlock()
            continuation.resume(throwing: CancellationError())

            return
        }

        if let haltError {
            lock.unlock()
            continuation.resume(throwing: haltError)

            return
        }

        fetchCompletionWaitersByID[id] = (predicate, continuation)
        lock.unlock()
    }

    func cancelWaiter(id: UUID) {
        var resumptions: [() -> Void] = []

        lock.lock()

        if let continuations = fetchContinuationsByOperationID.removeValue(forKey: id) {
            resumptions = continuations.map { continuation in
                { continuation.resume(throwing: CancellationError()) }
            }
        } else if let continuations = modifyContinuationsByCheckpointID.removeValue(forKey: id) {
            resumptions = continuations.map { continuation in
                { continuation.resume(throwing: CancellationError()) }
            }
        } else if let waiter = fetchCompletionWaitersByID.removeValue(forKey: id) {
            resumptions = [{ waiter.continuation.resume(throwing: CancellationError()) }]
        } else {
            cancelledWaiterIDs.insert(id)
        }

        lock.unlock()

        for resume in resumptions {
            resume()
        }
    }

    func handleFinalEvent(_ event: SyncEvent) {
        var resumptions: [() -> Void] = []

        lock.lock()

        switch event {
        case let .workSuccess(work, result):
            switch (work, result) {
            case let (.fetch(operation), .fetch(response)):
                if let continuations = fetchContinuationsByOperationID.removeValue(forKey: operation.id) {
                    resumptions += continuations.map { continuation in
                        { continuation.resume(returning: response) }
                    }
                }

                for (id, waiter) in fetchCompletionWaitersByID where waiter.predicate(operation, response) {
                    fetchCompletionWaitersByID[id] = nil
                    resumptions.append { waiter.continuation.resume(returning: (operation, response)) }
                }
            case let (.modify(operation), .modify(response)):
                if let checkpointID = operation.checkpointID,
                   let continuations = modifyContinuationsByCheckpointID.removeValue(forKey: checkpointID) {
                    resumptions += continuations.map { continuation in
                        { continuation.resume(returning: response) }
                    }
                }
            default:
                break
            }
        case let .workFailure(work, error):
            if case let .fetch(operation) = work {
                if let continuations = fetchContinuationsByOperationID.removeValue(forKey: operation.id) {
                    resumptions += continuations.map { continuation in
                        { continuation.resume(throwing: error) }
                    }
                }
            } else if case let .modify(operation) = work {
                if let checkpointID = operation.checkpointID,
                   let continuations = modifyContinuationsByCheckpointID.removeValue(forKey: checkpointID) {
                    resumptions += continuations.map { continuation in
                        { continuation.resume(throwing: error) }
                    }
                }
            }
        case let .halt(error):
            haltError = error

            for continuations in fetchContinuationsByOperationID.values {
                resumptions += continuations.map { continuation in
                    { continuation.resume(throwing: error) }
                }
            }
            fetchContinuationsByOperationID.removeAll()

            for continuations in modifyContinuationsByCheckpointID.values {
                resumptions += continuations.map { continuation in
                    { continuation.resume(throwing: error) }
                }
            }
            modifyContinuationsByCheckpointID.removeAll()

            for waiter in fetchCompletionWaitersByID.values {
                resumptions.append { waiter.continuation.resume(throwing: error) }
            }
            fetchCompletionWaitersByID.removeAll()
        case .start:
            haltError = nil
        default:
            break
        }

        lock.unlock()

        for resume in resumptions {
            resume()
        }
    }
}
