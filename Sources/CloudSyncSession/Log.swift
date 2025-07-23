import Logging

enum Log {
    private static let subsystem = "com.algebraiclabs.cloud-sync-session"
    
    public static let main = Logger(label: "\(subsystem).Main")
    public static let sync = Logger(label: "\(subsystem).Sync")
    public static let operations = Logger(label: "\(subsystem).Operations")
    public static let middleware = Logger(label: "\(subsystem).Middleware")
    public static let error = Logger(label: "\(subsystem).Error")
}