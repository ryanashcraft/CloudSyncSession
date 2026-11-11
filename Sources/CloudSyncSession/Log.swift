import Logging

enum Log {
    private static let subsystem = "com.algebraiclabs.cloud-sync-session"

    static let operations = Logger(label: "\(subsystem).Operations")
    static let session = Logger(label: "\(subsystem).Session")
    static let error = Logger(label: "\(subsystem).Error")
}
