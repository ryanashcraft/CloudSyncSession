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
