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
/// A reply is chosen when its request arrives and given after a suspension, so the session never
/// gets its answer on the spot.
final class ScriptedOperationHandler: OperationHandler {
    private let lock = NSLock()

    private var recordedCalls: [HandlerCall] = []
    private var inFlightCount = 0
    private var highestInFlightCount = 0
    private var attemptsByTag: [String: Int] = [:]

    private var modifyRule: ((ModifyRequest) -> ModifyReply?)?
    private var modifyReplies: [ModifyReply] = []
    private var fetchReplies: [FetchReply] = []
    private var createZoneReplies: [SetupReply] = []

    private var holding = Holding.nothing
    private var heldReplies: [UUID: CheckedContinuation<HeldReplyEnding, Never>] = [:]
    private var cancelledBeforeBeingHeld = Set<UUID>()
    private var cancelledCount = 0

    private enum Holding {
        case nothing
        case untilReleasedOrCancelled
        case untilReleased
    }

    private enum HeldReplyEnding {
        case released
        case cancelled
    }

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

    // MARK: Holding replies

    /// From now on a reply is still chosen when its request arrives, but it is not given until
    /// `releaseReplies()`. This is how a test acts while an operation is under way.
    ///
    /// A held request that the session cancels ends there, the way a real handler stops a
    /// cancelled operation. Pass `ignoringCancellation` for a request that carries on regardless,
    /// like one the server had already received, so that its reply arrives after the session has
    /// been stopped or reset.
    func holdReplies(ignoringCancellation: Bool = false) {
        withLock { holding = ignoringCancellation ? .untilReleased : .untilReleasedOrCancelled }
    }

    /// Gives the held replies and goes back to replying straight away.
    func releaseReplies() {
        let continuations: [CheckedContinuation<HeldReplyEnding, Never>] = withLock {
            defer { heldReplies = [:] }

            holding = .nothing

            return Array(heldReplies.values)
        }

        for continuation in continuations {
            continuation.resume(returning: .released)
        }
    }

    /// Whether a request has arrived whose reply is being held.
    var hasHeldReply: Bool {
        withLock { !heldReplies.isEmpty }
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

    /// How many requests ended because the session cancelled them.
    var cancelledCallCount: Int {
        withLock { cancelledCount }
    }

    // MARK: OperationHandler

    func handle(createZoneOperation _: CreateZoneOperation) async throws -> Bool {
        let reply: SetupReply = withLock {
            begin(.createZone)

            return createZoneReplies.isEmpty ? .succeed : createZoneReplies.removeFirst()
        }

        try await waitToReply()

        switch reply {
        case .succeed:
            return true
        case let .fail(code):
            throw CKError(code)
        }
    }

    func handle(createSubscriptionOperation _: CreateSubscriptionOperation) async throws -> Bool {
        withLock { begin(.createSubscription) }

        try await waitToReply()

        return true
    }

    func handle(fetchOperation: FetchOperation) async throws -> FetchOperation.Response {
        let reply: FetchReply = withLock {
            begin(.fetch)

            return fetchReplies.isEmpty ? .page(changed: 0, hasMore: false) : fetchReplies.removeFirst()
        }

        try await waitToReply()

        switch reply {
        case let .page(changed, hasMore):
            return FetchOperation.Response(
                changeToken: fetchOperation.changeToken,
                changedRecords: (0 ..< changed).map { _ in makeRecord() },
                deletedRecordIDs: [],
                hasMore: hasMore
            )
        case let .fail(code):
            throw CKError(code)
        }
    }

    func handle(modifyOperation: ModifyOperation) async throws -> ModifyOperation.Response {
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

        try await waitToReply()

        switch reply {
        case .succeed:
            return ModifyOperation.Response(
                savedRecords: modifyOperation.records,
                deletedRecordIDs: modifyOperation.recordIDsToDelete
            )
        case let .fail(code):
            throw CKError(code)
        case let .partialFailure(codesBySaveIndex):
            throw makePartialFailure(for: modifyOperation, codesBySaveIndex: codesBySaveIndex)
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

    /// Suspends until it is time to give the reply, and counts the request as no longer
    /// outstanding from that moment. Throws if the request was cancelled while its reply was held.
    private func waitToReply() async throws {
        let ending = await suspendUntilTimeToReply()

        withLock {
            inFlightCount -= 1

            if ending == .cancelled {
                cancelledCount += 1
            }
        }

        if ending == .cancelled {
            throw CancellationError()
        }
    }

    private func suspendUntilTimeToReply() async -> HeldReplyEnding {
        switch withLock({ holding }) {
        case .nothing:
            await Task.yield()

            return .released
        case .untilReleased:
            let id = UUID()

            return await withCheckedContinuation { continuation in
                withLock { heldReplies[id] = continuation }
            }
        case .untilReleasedOrCancelled:
            let id = UUID()

            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let wasCancelled: Bool = withLock {
                        if cancelledBeforeBeingHeld.remove(id) != nil {
                            return true
                        }

                        heldReplies[id] = continuation

                        return false
                    }

                    if wasCancelled {
                        continuation.resume(returning: .cancelled)
                    }
                }
            } onCancel: {
                let continuation: CheckedContinuation<HeldReplyEnding, Never>? = withLock {
                    if let continuation = heldReplies.removeValue(forKey: id) {
                        return continuation
                    }

                    cancelledBeforeBeingHeld.insert(id)

                    return nil
                }

                continuation?.resume(returning: .cancelled)
            }
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
