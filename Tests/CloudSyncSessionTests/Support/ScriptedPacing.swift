@testable import CloudSyncSession
import Foundation

/// Stands in for the session's real waits. By default every wait ends at once, so tests do not
/// run in real time. A test can instead hold one kind of wait open, to act while the session is
/// in it, and then release it.
///
/// A held wait also ends, by throwing, when the session cancels it. That is what `stop()` and
/// `reset()` do.
final class ScriptedPacing: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPauses: [Pause] = []
    private var holdsWorkDelay = false
    private var holdsRetryBackoff = false
    private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledBeforeWaiting = Set<UUID>()

    var pacing: Pacing {
        Pacing { [self] pause in
            try await self.pause(pause)
        }
    }

    // MARK: Scripting

    /// Hold the gap the session leaves before sending work.
    func holdWorkDelay() {
        withLock { holdsWorkDelay = true }
    }

    /// Hold the wait before failed work is tried again.
    func holdRetryBackoff() {
        withLock { holdsRetryBackoff = true }
    }

    /// End every held wait and stop holding new ones.
    func release() {
        let continuations: [CheckedContinuation<Void, Error>] = withLock {
            defer { waiting = [:] }

            holdsWorkDelay = false
            holdsRetryBackoff = false

            return Array(waiting.values)
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    // MARK: Observation

    /// Whether the session is in a wait that is being held.
    var isHolding: Bool {
        withLock { !waiting.isEmpty }
    }

    /// How long the session waited before each retry, in seconds and in order.
    var retryBackoffs: [TimeInterval] {
        withLock {
            recordedPauses.compactMap { pause in
                if case let .retryBackoff(seconds) = pause {
                    return seconds
                }

                return nil
            }
        }
    }

    // MARK: Private

    private func pause(_ pause: Pause) async throws {
        let shouldHold: Bool = withLock {
            recordedPauses.append(pause)

            switch pause {
            case .beforeWork:
                return holdsWorkDelay
            case .retryBackoff:
                return holdsRetryBackoff
            }
        }

        guard shouldHold else {
            try Task.checkCancellation()

            return
        }

        let id = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let wasCancelled: Bool = withLock {
                    if cancelledBeforeWaiting.remove(id) != nil {
                        return true
                    }

                    waiting[id] = continuation

                    return false
                }

                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = withLock {
                if let continuation = waiting.removeValue(forKey: id) {
                    return continuation
                }

                cancelledBeforeWaiting.insert(id)

                return nil
            }

            continuation?.resume(throwing: CancellationError())
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }

        return body()
    }
}
