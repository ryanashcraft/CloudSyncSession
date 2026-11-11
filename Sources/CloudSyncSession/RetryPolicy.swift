import Foundation

/// How long to wait before trying failed work again, and when to stop trying.
enum RetryPolicy {
    /// How many times one piece of work may be retried before the session halts.
    static let maxRetryCount = 5

    enum Decision: Equatable {
        /// Wait this many seconds, then try again.
        case wait(TimeInterval)

        /// The work has used up its retries.
        case giveUp
    }

    /// - Parameter retryCount: How many times the work has already been retried.
    /// - Parameter suggestedInterval: The wait the server asked for, if it asked for one.
    static func decision(retryCount: Int, suggestedInterval: TimeInterval?) -> Decision {
        guard retryCount + 1 <= maxRetryCount else {
            return .giveUp
        }

        return .wait(suggestedInterval ?? TimeInterval(pow(Double(retryCount), 2.0)))
    }
}
