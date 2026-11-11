import Logging

enum Log<Backend: SyncBackend> {
    static var session: Logger {
        Logger(label: "\(Backend.logSubsystem).Session")
    }
}
