import Foundation
@testable import SyncSessionCore

/// A backend with nothing behind it, for testing the session's own rules. It has two setup steps,
/// in the order CloudKit has them, so that the rules about setup have something to act on.
enum TestBackend: SyncBackend {
    struct Record: Equatable {
        let recordID: String
    }

    typealias RecordID = String
    typealias ChangeToken = Int

    enum AccountStatus {
        case available
        case unavailable
    }

    enum SetupStep: Hashable, Sendable {
        case zone
        case subscription
    }

    struct StopError: Error {}

    static let setupSteps: [SetupStep] = [.zone, .subscription]
    static let maxItemsPerModify = 400
    static let logSubsystem = "sync-session-core-tests"

    static func isAvailable(_ status: AccountStatus) -> Bool {
        status == .available
    }

    static func makeStopError() -> Error {
        StopError()
    }
}

struct TestError: Error {}

typealias SyncState = SessionState<TestBackend>
typealias SyncWork = SessionWork<TestBackend>
typealias FetchOperation = SessionFetchOperation<TestBackend>
typealias ModifyOperation = SessionModifyOperation<TestBackend>
typealias SetupOperation = SessionSetupOperation<TestBackend>

func makeRecord() -> TestBackend.Record {
    TestBackend.Record(recordID: UUID().uuidString)
}
