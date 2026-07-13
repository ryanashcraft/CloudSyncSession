import Foundation

/// A thread safe fan-out from one producer to any number of AsyncStreams.
///
/// Each call to makeStream() returns an independent stream whose buffer is
/// registered before the call returns: a stream created before an element is
/// sent observes that element whether or not iteration has started. This
/// mirrors how a Combine subject delivers to every current subscriber, which
/// a bare AsyncStream does not.
///
/// A broadcast with replaysLatest set behaves like CurrentValueSubject: the
/// latest element (starting from initialElement, when provided) is delivered
/// as the first element of every new stream. Event broadcasts never replay.
///
/// Unbounded event broadcasts carry a consume promptly contract: elements
/// buffer per stream until iterated, so a created-but-never-iterated stream
/// grows without bound. Create streams where they will be consumed.
final class AsyncBroadcast<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private let replaysLatest: Bool
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy
    private var continuationsByID: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latestElement: Element?

    init(
        replaysLatest: Bool,
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy,
        initialElement: Element? = nil
    ) {
        self.replaysLatest = replaysLatest
        self.bufferingPolicy = bufferingPolicy
        latestElement = initialElement
    }

    func send(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }

        if replaysLatest {
            latestElement = element
        }

        for continuation in continuationsByID.values {
            continuation.yield(element)
        }
    }

    func makeStream() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()

            lock.lock()
            continuationsByID[id] = continuation

            if replaysLatest, let latestElement {
                continuation.yield(latestElement)
            }
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    private func removeContinuation(id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        continuationsByID[id] = nil
    }
}
