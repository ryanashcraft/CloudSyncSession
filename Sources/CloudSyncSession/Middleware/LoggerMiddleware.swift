struct LoggerMiddleware: Middleware {
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        Log.middleware.debug("\(event.logDescription)")

        return next(event)
    }
}
