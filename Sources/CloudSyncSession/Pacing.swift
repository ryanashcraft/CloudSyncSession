import Foundation

/// A wait the session inserts into its own work.
enum Pause: Equatable, Sendable {
    /// The short gap between work reaching the head of the queue and being sent.
    case beforeWork

    /// The wait before failed work is tried again, in seconds.
    case retryBackoff(TimeInterval)

    var duration: TimeInterval {
        switch self {
        case .beforeWork:
            return 0.06
        case let .retryBackoff(seconds):
            return seconds
        }
    }
}

/// How the session waits. Tests substitute their own so they do not wait in real time.
///
/// `pause` must throw when its task is cancelled, which is how `stop()` and `reset()` cut a wait
/// short.
struct Pacing: Sendable {
    var pause: @Sendable (Pause) async throws -> Void

    static let live = Pacing { pause in
        try await Task.sleep(nanoseconds: UInt64(max(0, pause.duration) * 1_000_000_000))
    }
}
