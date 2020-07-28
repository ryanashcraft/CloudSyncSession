typealias Next = (SyncEvent) -> SyncEvent

struct AnyMiddleware: Middleware {
    init<M: Middleware>(value: M) {
        self.session = value.session
        self.run = value.run
    }

    var session: CloudSyncSession
    var run: (_ next: Next, _ event: SyncEvent) -> SyncEvent

    func run(next: Next, event: SyncEvent) -> SyncEvent {
        run(next, event)
    }
}

protocol Middleware {
    var session: CloudSyncSession { get }

    func eraseToAnyMiddleware() -> AnyMiddleware
    func run(next: Next, event: SyncEvent) -> SyncEvent
}

extension Middleware {
    func eraseToAnyMiddleware() -> AnyMiddleware {
        return AnyMiddleware(value: self)
    }
}
