import Foundation
@testable import SyncSessionCore
import XCTest

/// How the scripted backend answers one fetch or modify request.
enum Reply {
    /// A modify saves and deletes everything it was asked to. A fetch returns one empty page.
    case succeed

    /// A fetch returns a page that reports more to come.
    case succeedWithMore

    case fail(ScriptedFailure)

    /// The request waits until the test answers through the gate, or until its task is cancelled,
    /// which fails it.
    case hold(Gate)

    /// As `hold`, but the request ignores cancellation, the way a request the server already has does.
    case holdThroughCancellation(Gate)
}

/// A failure the scripted backend can report, named for what the session is told to do about it.
enum ScriptedFailure: Error, Equatable {
    case halt
    case retry
    case split

    /// Send the modify again with this many records.
    case resend(recordCount: Int)
}

/// Lets a test answer a held request when it chooses.
struct Gate {
    fileprivate let answers: AsyncStream<Reply>
    private let continuation: AsyncStream<Reply>.Continuation

    init() {
        (answers, continuation) = AsyncStream<Reply>.makeStream()
    }

    func succeed() {
        continuation.yield(.succeed)
    }

    func fail(_ failure: ScriptedFailure) {
        continuation.yield(.fail(failure))
    }
}

private actor Script {
    private var replies: [Reply] = []

    func add(_ reply: Reply) {
        replies.append(reply)
    }

    func nextReply() -> Reply {
        replies.isEmpty ? .succeed : replies.removeFirst()
    }
}

/// A real `SyncSession` over `TestBackend`, with a backend that answers from a script and waits
/// that never wait. Setup steps always succeed and are not reported as requests.
///
/// Use one from a single test function: reading requests and events is not safe from two tasks.
final class TestSession {
    let session: SyncSession<TestBackend>

    private let script = Script()
    private var requests: AsyncStream<SyncWork>.Iterator
    private var events: AsyncStream<SyncSession<TestBackend>.Event>.Iterator

    /// - Parameter holdsRetryBackoff: Whether the wait before a retry lasts until the session cuts it short.
    init(holdsRetryBackoff: Bool = false) {
        let script = script
        let (neverEnding, _) = AsyncStream<Never>.makeStream()
        let (requests, requestContinuation) = AsyncStream<SyncWork>.makeStream()

        session = SyncSession<TestBackend>(
            perform: { work in
                if case .setup = work {
                    return .success(.setup(true))
                }

                requestContinuation.yield(work)

                var reply = await script.nextReply()

                switch reply {
                case let .hold(gate):
                    guard let answer = await gate.answers.first(where: { _ in true }) else {
                        return .failure(CancellationError())
                    }

                    reply = answer
                case let .holdThroughCancellation(gate):
                    // An unstructured task does not inherit the cancellation of the one that awaits it.
                    reply = await Task { await gate.answers.first(where: { _ in true }) ?? .fail(.halt) }.value
                default:
                    break
                }

                switch (reply, work) {
                case let (.fail(failure), _):
                    return .failure(failure)
                case let (_, .modify(operation)):
                    return .success(.modify(.init(savedRecords: operation.records, deletedRecordIDs: operation.recordIDsToDelete)))
                case let (.succeedWithMore, .fetch(operation)):
                    return .success(.fetch(.init(changeToken: (operation.changeToken ?? 0) + 1, changedRecords: [makeRecord()], deletedRecordIDs: [], hasMore: true)))
                case let (_, .fetch(operation)):
                    return .success(.fetch(.init(changeToken: (operation.changeToken ?? 0) + 1, changedRecords: [], deletedRecordIDs: [], hasMore: false)))
                case (_, .setup):
                    return .success(.setup(true))
                }
            },
            resolveFailure: { error, work in
                switch error as? ScriptedFailure {
                case .retry:
                    return .retry(work, error, 0)
                case .split:
                    return .split(error)
                case let .resend(recordCount):
                    return .resend(records: (0 ..< recordCount).map { _ in makeRecord() }, recordIDsToDelete: [])
                case .halt, nil:
                    return .halt(error)
                }
            },
            pacing: Pacing { pause in
                if holdsRetryBackoff, case .retryBackoff = pause {
                    for await _ in neverEnding {}
                }

                try Task.checkCancellation()
            }
        )

        self.requests = requests.makeAsyncIterator()
        events = session.events.makeAsyncIterator()
    }

    /// Starts the session with an available account.
    func startRunning() {
        session.start()
        session.accountStatusChanged(.available)
    }

    // MARK: Scripting

    /// Sets how the next unanswered request is answered. Calls queue up in order.
    func reply(_ replies: Reply...) async {
        for reply in replies {
            await script.add(reply)
        }
    }

    /// Makes the next unanswered request wait for the returned gate.
    func hold() async -> Gate {
        let gate = Gate()

        await script.add(.hold(gate))

        return gate
    }

    /// Makes the next unanswered request wait for the returned gate even after it is cancelled.
    func holdThroughCancellation() async -> Gate {
        let gate = Gate()

        await script.add(.holdThroughCancellation(gate))

        return gate
    }

    // MARK: Observing

    /// The next fetch or modify request to reach the backend. Waits for one if none has yet.
    @discardableResult
    func nextRequest() async -> SyncWork {
        await requests.next()!
    }

    /// Reads events, from where the last call stopped, up to the first one that matches.
    func waitForEvent(_ matches: (SyncSession<TestBackend>.Event) -> Bool) async {
        while let event = await events.next() {
            if matches(event) {
                return
            }
        }
    }

    /// Waits until work from a `perform` call has been queued.
    func waitForPerformToQueue() async {
        await waitForEvent { event in
            if case let .doWork(work) = event {
                return work.performID != nil
            }

            return false
        }
    }

    func waitForHalt() async {
        await waitForEvent { event in
            if case .halt = event {
                return true
            }

            return false
        }
    }
}

func makeModify(saves: Int = 1, deletes: Int = 0, checkpointID: UUID? = UUID()) -> ModifyOperation {
    ModifyOperation(
        records: (0 ..< saves).map { _ in makeRecord() },
        recordIDsToDelete: (0 ..< deletes).map { _ in UUID().uuidString },
        checkpointID: checkpointID,
        userInfo: nil
    )
}

func assertThrows<Value>(
    _ expected: (Error) -> Bool,
    _ description: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Value
) async {
    do {
        _ = try await body()

        XCTFail("Expected \(description), but nothing was thrown", file: file, line: line)
    } catch {
        XCTAssertTrue(expected(error), "Expected \(description), got \(error)", file: file, line: line)
    }
}

func isStopped(_ error: Error) -> Bool {
    if case SessionInterruption.stopped = error {
        return true
    }

    return false
}

func isReset(_ error: Error) -> Bool {
    if case SessionInterruption.reset = error {
        return true
    }

    return false
}

func isHalted(_ error: Error) -> Bool {
    if case let SessionInterruption.halted(cause) = error {
        return cause as? ScriptedFailure == .halt
    }

    return false
}
