import CloudKit
@testable import CloudSyncSession
import Foundation

/// One request that reached the operation handler.
enum HandlerCall: Equatable, CustomStringConvertible {
    case createZone
    case createSubscription
    case fetch
    case modify(_ tag: String, saves: Int, deletes: Int = 0)

    var description: String {
        switch self {
        case .createZone:
            return "createZone"
        case .createSubscription:
            return "createSubscription"
        case .fetch:
            return "fetch"
        case let .modify(tag, saves, deletes):
            return deletes == 0 ? "modify(\(tag), saves: \(saves))" : "modify(\(tag), saves: \(saves), deletes: \(deletes))"
        }
    }

    var isSetup: Bool {
        self == .createZone || self == .createSubscription
    }
}

/// How the handler answers one modify request.
enum ModifyReply {
    /// Every record is saved and every deletion applied.
    case succeed

    /// The whole request fails with this CloudKit error code.
    case fail(CKError.Code)

    /// The request fails as an atomic batch. The saves at the given indexes fail with the given
    /// codes and everything else in the request fails with `batchRequestFailed`, which is what
    /// CloudKit reports for the untouched items of an atomic zone.
    case partialFailure([Int: CKError.Code])
}

/// How the handler answers one fetch request.
enum FetchReply {
    case page(changed: Int, hasMore: Bool)
    case fail(CKError.Code)
}

/// How the handler answers a create-zone or create-subscription request.
enum SetupReply {
    case succeed
    case fail(CKError.Code)
}

/// What a modify rule is told about the request it is answering.
struct ModifyRequest {
    let tag: String
    let saves: Int
    let deletes: Int

    /// 1 for the first request carrying this tag, 2 for the second, and so on.
    let attempt: Int
}

/// An `OperationHandler` that answers from a script and records every request in order.
///
/// Replies are chosen when the request arrives and delivered asynchronously on a private serial
/// queue, the way CloudKit completes on its own threads.
final class ScriptedOperationHandler: OperationHandler {
    private let lock = NSLock()
    private let replyQueue = DispatchQueue(label: "ScriptedOperationHandler.Reply")

    private var recordedCalls: [HandlerCall] = []
    private var inFlightCount = 0
    private var highestInFlightCount = 0
    private var attemptsByTag: [String: Int] = [:]

    private var modifyRule: ((ModifyRequest) -> ModifyReply?)?
    private var modifyReplies: [ModifyReply] = []
    private var fetchReplies: [FetchReply] = []
    private var createZoneReplies: [SetupReply] = []

    // MARK: Scripting

    /// Replies for successive modify requests, whatever their tag. Once used up, requests succeed.
    func scriptModify(_ replies: ModifyReply...) {
        withLock { modifyReplies.append(contentsOf: replies) }
    }

    /// Consulted before the scripted replies. Return nil to fall through to them.
    func scriptModify(rule: @escaping (ModifyRequest) -> ModifyReply?) {
        withLock { modifyRule = rule }
    }

    /// Replies for successive fetch requests. Once used up, fetches return an empty final page.
    func scriptFetch(_ replies: FetchReply...) {
        withLock { fetchReplies.append(contentsOf: replies) }
    }

    /// Replies for successive create-zone requests. Once used up, they succeed.
    func scriptCreateZone(_ replies: SetupReply...) {
        withLock { createZoneReplies.append(contentsOf: replies) }
    }

    // MARK: Observation

    var calls: [HandlerCall] {
        withLock { recordedCalls }
    }

    var isIdle: Bool {
        withLock { inFlightCount == 0 }
    }

    /// The most requests that were ever outstanding at the same moment.
    var maxConcurrentCalls: Int {
        withLock { highestInFlightCount }
    }

    // MARK: OperationHandler

    func handle(createZoneOperation _: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void) {
        let reply: SetupReply = withLock {
            begin(.createZone)

            return createZoneReplies.isEmpty ? .succeed : createZoneReplies.removeFirst()
        }

        finish {
            switch reply {
            case .succeed:
                completion(.success(true))
            case let .fail(code):
                completion(.failure(CKError(code)))
            }
        }
    }

    func handle(createSubscriptionOperation _: CreateSubscriptionOperation, completion: @escaping (Result<Bool, Error>) -> Void) {
        withLock { begin(.createSubscription) }

        finish {
            completion(.success(true))
        }
    }

    func handle(fetchOperation: FetchOperation, completion: @escaping (Result<FetchOperation.Response, Error>) -> Void) {
        let reply: FetchReply = withLock {
            begin(.fetch)

            return fetchReplies.isEmpty ? .page(changed: 0, hasMore: false) : fetchReplies.removeFirst()
        }

        finish {
            switch reply {
            case let .page(changed, hasMore):
                completion(
                    .success(
                        FetchOperation.Response(
                            changeToken: fetchOperation.changeToken,
                            changedRecords: (0 ..< changed).map { _ in makeRecord() },
                            deletedRecordIDs: [],
                            hasMore: hasMore
                        )
                    )
                )
            case let .fail(code):
                completion(.failure(CKError(code)))
            }
        }
    }

    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void) {
        let tag = modifyOperation.tag
        let saves = modifyOperation.records.count
        let deletes = modifyOperation.recordIDsToDelete.count

        let reply: ModifyReply = withLock {
            begin(.modify(tag, saves: saves, deletes: deletes))

            let attempt = attemptsByTag[tag, default: 0] + 1
            attemptsByTag[tag] = attempt

            if let ruled = modifyRule?(ModifyRequest(tag: tag, saves: saves, deletes: deletes, attempt: attempt)) {
                return ruled
            }

            return modifyReplies.isEmpty ? .succeed : modifyReplies.removeFirst()
        }

        finish {
            switch reply {
            case .succeed:
                completion(
                    .success(
                        ModifyOperation.Response(
                            savedRecords: modifyOperation.records,
                            deletedRecordIDs: modifyOperation.recordIDsToDelete
                        )
                    )
                )
            case let .fail(code):
                completion(.failure(CKError(code)))
            case let .partialFailure(codesBySaveIndex):
                completion(.failure(makePartialFailure(for: modifyOperation, codesBySaveIndex: codesBySaveIndex)))
            }
        }
    }

    // MARK: Private

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }

        return body()
    }

    /// Call with the lock held.
    private func begin(_ call: HandlerCall) {
        recordedCalls.append(call)
        inFlightCount += 1
        highestInFlightCount = max(highestInFlightCount, inFlightCount)
    }

    private func finish(_ deliver: @escaping () -> Void) {
        replyQueue.async {
            deliver()

            self.withLock { self.inFlightCount -= 1 }
        }
    }
}

extension ModifyOperation {
    static let tagKey = "tag"

    /// The label the test gave this operation. Splitting and conflict requeues carry `userInfo`
    /// forward, so every piece of an operation keeps the tag of the original.
    var tag: String {
        userInfo?[Self.tagKey] as? String ?? "untagged"
    }
}

func makeRecord() -> CKRecord {
    CKRecord(recordType: "Test", recordID: CKRecord.ID(recordName: UUID().uuidString))
}

/// The marker field the fake server stamps on the server copy of a conflicted record.
let serverCopyMarkerKey = "serverCopy"

/// Builds the error CloudKit's `modifyRecordsCompletionBlock` reports when an atomic batch fails:
/// a `partialFailure` whose per-item errors cover every save and every deletion in the request.
private func makePartialFailure(for operation: ModifyOperation, codesBySaveIndex: [Int: CKError.Code]) -> CKError {
    var errorsByItemID: [CKRecord.ID: CKError] = [:]

    for (index, record) in operation.records.enumerated() {
        switch codesBySaveIndex[index] {
        case .serverRecordChanged?:
            let serverRecord = CKRecord(recordType: record.recordType, recordID: record.recordID)
            serverRecord[serverCopyMarkerKey] = true

            errorsByItemID[record.recordID] = CKError(
                .serverRecordChanged,
                userInfo: [
                    CKRecordChangedErrorClientRecordKey: record,
                    CKRecordChangedErrorServerRecordKey: serverRecord,
                ]
            )
        case let code?:
            errorsByItemID[record.recordID] = CKError(code)
        case nil:
            errorsByItemID[record.recordID] = CKError(.batchRequestFailed)
        }
    }

    for recordID in operation.recordIDsToDelete {
        errorsByItemID[recordID] = CKError(.batchRequestFailed)
    }

    return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: errorsByItemID])
}
