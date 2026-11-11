import CloudKit
import XCTest

/// Randomized checks of the modify queue. Each scenario is generated from a seed, so a failure
/// names the seed that reproduces it.
///
/// The invariants, for any mix of operations:
/// - every record of every operation is saved exactly once;
/// - operations complete in the order they were submitted, with the pieces of a split operation
///   kept together;
/// - the handler never has more than one request outstanding;
/// - the session does not halt.
final class SessionQueueInvariantTests: XCTestCase {
    func testInvariantsHoldWithoutFaults() {
        for seed: UInt64 in [1, 2] {
            runScenario(seed: seed, operationCount: 15, withFaults: false)
        }
    }

    /// With transient failures and oversized operations in the mix, the ordering invariant breaks:
    /// see the ordering tests in `SessionKnownDefectTests`.
    func testInvariantsHoldWithTransientFailuresAndOversizedOperations() {
        XCTExpectFailure("Retried and split modifies lose their place in the queue", strict: true) {
            runScenario(seed: 3, operationCount: 15, withFaults: true)
        }
    }

    private func runScenario(seed: UInt64, operationCount: Int, withFaults: Bool, file: StaticString = #filePath, line: UInt = #line) {
        var generator = SeededGenerator(seed: seed)
        var plan: [(tag: String, saves: Int)] = []
        var tagsFailingOnce = Set<String>()

        for index in 0 ..< operationCount {
            let tag = "op\(index)"
            let isOversized = withFaults && Double.random(in: 0 ..< 1, using: &generator) < 0.15

            plan.append((tag, isOversized ? Int.random(in: 401 ... 450, using: &generator) : Int.random(in: 1 ... 5, using: &generator)))

            if withFaults, !isOversized, Double.random(in: 0 ..< 1, using: &generator) < 0.3 {
                tagsFailingOnce.insert(tag)
            }
        }

        let harness = makeHarness()
        harness.handler.scriptModify(rule: { request in
            tagsFailingOnce.contains(request.tag) && request.attempt == 1 ? .fail(.networkUnavailable) : nil
        })
        harness.startRunning(file: file, line: line)

        for operation in plan {
            harness.modify(operation.tag, saves: operation.saves)
        }

        guard harness.settle(timeout: 30, file: file, line: line) else {
            return
        }

        var savedByTag: [String: Int] = [:]
        var completionOrder: [String] = []

        for completion in harness.completions {
            guard case let .modify(tag, saved, _, _) = completion else {
                continue
            }

            savedByTag[tag, default: 0] += saved

            if completionOrder.last != tag {
                completionOrder.append(tag)
            }
        }

        let context = "seed \(seed)"

        XCTAssertEqual(savedByTag, Dictionary(uniqueKeysWithValues: plan.map { ($0.tag, $0.saves) }), "Every record must be saved exactly once (\(context))", file: file, line: line)
        XCTAssertEqual(completionOrder, plan.map(\.tag), "Operations must complete in submission order (\(context))", file: file, line: line)
        XCTAssertEqual(harness.handler.maxConcurrentCalls, 1, "Only one request may be outstanding at a time (\(context))", file: file, line: line)
        XCTAssertFalse(harness.isHalted, "The session must not halt (\(context))", file: file, line: line)
    }
}

/// SplitMix64: a small deterministic generator, so a scenario is fully determined by its seed.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15

        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB

        return z ^ (z >> 31)
    }
}
