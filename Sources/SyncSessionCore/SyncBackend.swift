import Foundation

/// Describes the server a session syncs with: the types it trades in and the few facts about it
/// that the session needs. A backend is never instantiated; it only names things, which is also
/// why it can be `Sendable` whatever its record type is.
///
/// The session itself is the same for every backend. What differs lives outside it: how an
/// operation is carried out, and what to do about each error the server can report. A backend's
/// library supplies those to `SyncSession`'s initializer.
public protocol SyncBackend: Sendable {
    /// A record as the server stores it.
    associatedtype Record

    /// What identifies a record.
    associatedtype RecordID: Hashable

    /// Marks a point in the server's history of changes, to fetch from.
    associatedtype ChangeToken: Equatable

    /// What the backend reports about the user's account.
    associatedtype AccountStatus

    /// Something that must exist on the server before records can be fetched or modified, such as
    /// a CloudKit zone. A backend with nothing to set up uses `Never`.
    associatedtype SetupStep: Hashable

    /// Every setup step, in the order they must be done.
    static var setupSteps: [SetupStep] { get }

    /// The most records and deletions one modify request may carry. A larger modify is queued as several.
    static var maxItemsPerModify: Int { get }

    /// Prefix for the labels of the session's loggers.
    static var logSubsystem: String { get }

    /// Whether the account can be used to sync.
    static func isAvailable(_ status: AccountStatus) -> Bool

    /// The error a session reports when it is halted by `stop()` rather than by a failure.
    static func makeStopError() -> Error

    /// How to name an account status in the log.
    static func describe(_ status: AccountStatus) -> String

    /// How to name a setup step in the log.
    static func describe(_ step: SetupStep) -> String
}

public extension SyncBackend {
    static func describe(_ status: AccountStatus) -> String {
        String(describing: status)
    }

    static func describe(_ step: SetupStep) -> String {
        String(describing: step)
    }
}

public extension SyncBackend where SetupStep == Never {
    static var setupSteps: [Never] {
        []
    }
}
