import os.log

struct LoggerMiddleware: Middleware {
    var session: CloudSyncSession

    var log = OSLog(
        subsystem: "com.algebraiclabs.CloudSyncSession",
        category: "event"
    )

    func run(next: Next, event: SyncEvent) -> SyncEvent {
        os_log("%{public}@", log: log, type: .debug, event.logDescription)

        return next(event)
    }
}
