import Foundation

extension OperationHandler {
    /// Hands one piece of work to the handler and waits for its result.
    func perform(_ work: SyncWork) async -> Result<SyncWork.Result, Error> {
        switch work {
        case let .fetch(operation):
            return await awaitCompletion { self.handle(fetchOperation: operation, completion: $0) }
                .map(SyncWork.Result.fetch)
        case let .modify(operation):
            return await awaitCompletion { self.handle(modifyOperation: operation, completion: $0) }
                .map(SyncWork.Result.modify)
        case let .createZone(operation):
            return await awaitCompletion { self.handle(createZoneOperation: operation, completion: $0) }
                .map(SyncWork.Result.createZone)
        case let .createSubscription(operation):
            return await awaitCompletion { self.handle(createSubscriptionOperation: operation, completion: $0) }
                .map(SyncWork.Result.createSubscription)
        }
    }
}

/// Suspends until the completion handler passed to `start` is called.
private func awaitCompletion<Value>(
    _ start: (@escaping (Result<Value, Error>) -> Void) -> Void
) async -> Result<Value, Error> {
    await withCheckedContinuation { continuation in
        let completion = SingleCompletion(continuation)

        start { result in
            completion.complete(with: result)
        }
    }
}

/// Resumes a continuation the first time a handler reports a result and ignores any later report.
/// A handler that completes twice is a bug in the handler, but resuming a continuation twice
/// would crash the app, so the extra result is logged and dropped.
private final class SingleCompletion<Value> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Value, Error>, Never>?

    init(_ continuation: CheckedContinuation<Result<Value, Error>, Never>) {
        self.continuation = continuation
    }

    func complete(with result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else {
            Log.operations.error("An operation handler reported a result more than once. The extra result was ignored.")

            return
        }

        continuation.resume(returning: result)
    }
}
