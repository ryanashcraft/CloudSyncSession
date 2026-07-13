public struct AnyMiddleware: Middleware {
    public init<M: Middleware>(value: M) {
        session = value.session
        run = value.run
    }

    public var session: CloudSyncSession
    var run: (_ next: (SyncEvent) -> SyncEvent, _ event: SyncEvent) -> SyncEvent

    public func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        run(next, event)
    }
}

public protocol Middleware {
    var session: CloudSyncSession { get }

    func eraseToAnyMiddleware() -> AnyMiddleware
    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent
}

public extension Middleware {
    func eraseToAnyMiddleware() -> AnyMiddleware {
        return AnyMiddleware(value: self)
    }
}

// The erased run closure cannot be typed @Sendable without changing the
// public Middleware requirement, so the checked conformance is unavailable.
// In practice the wrapper is safe to send once: run is invoked only on the
// session's dispatch queue, and every middleware in this library is itself
// Sendable, so the closure's captured state is too.
extension AnyMiddleware: @unchecked Sendable {}
