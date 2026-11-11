import Foundation

/// How long to leave between one request to the server and the next.
///
/// This only does the arithmetic. Whoever sends the requests tells it how each one ended and
/// does the waiting.
public struct Throttle: Equatable, Sendable {
    public static let minDuration: TimeInterval = 0.25
    public static let maxDuration: TimeInterval = 60 * 10

    /// What one finished request says about the load the server is under.
    public enum Signal: Equatable, Sendable {
        /// The request succeeded, or failed for a reason that has nothing to do with load.
        case noPressure
        /// The server is under load and did not say how long to wait.
        case pressure
        /// The server asked for this many seconds before the next request.
        case waitRequested(TimeInterval)
    }

    /// The gap to leave, in seconds.
    public private(set) var duration: TimeInterval = Throttle.minDuration

    public init() {}

    public mutating func record(_ signal: Signal) {
        switch signal {
        case .noPressure:
            duration = max(Self.minDuration, duration * 2 / 3)
        case .pressure:
            duration = min(Self.maxDuration, duration * 2)
        case let .waitRequested(seconds):
            // Held to the floor as well as the cap: doubling a duration of zero would leave it
            // at zero.
            duration = max(Self.minDuration, min(Self.maxDuration, seconds))
        }
    }
}
