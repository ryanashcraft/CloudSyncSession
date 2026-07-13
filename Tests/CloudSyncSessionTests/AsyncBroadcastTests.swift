@testable import CloudSyncSession
import XCTest

final class AsyncBroadcastTests: XCTestCase {
    func testStreamCreatedBeforeSendObservesElement() async {
        let broadcast = AsyncBroadcast<Int>(replaysLatest: false, bufferingPolicy: .unbounded)
        let stream = broadcast.makeStream()

        broadcast.send(7)

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()

        XCTAssertEqual(first, 7)
    }

    func testMulticastsToEveryStream() async {
        let broadcast = AsyncBroadcast<Int>(replaysLatest: false, bufferingPolicy: .unbounded)
        let firstStream = broadcast.makeStream()
        let secondStream = broadcast.makeStream()

        broadcast.send(1)
        broadcast.send(2)

        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()

        let firstElements = [await firstIterator.next(), await firstIterator.next()]
        let secondElements = [await secondIterator.next(), await secondIterator.next()]

        XCTAssertEqual(firstElements, [1, 2])
        XCTAssertEqual(secondElements, [1, 2])
    }

    func testEventBroadcastDoesNotReplay() async {
        let broadcast = AsyncBroadcast<Int>(replaysLatest: false, bufferingPolicy: .unbounded)

        broadcast.send(1)

        let stream = broadcast.makeStream()
        broadcast.send(2)

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()

        XCTAssertEqual(first, 2)
    }

    func testStateBroadcastReplaysLatest() async {
        let broadcast = AsyncBroadcast<Int>(replaysLatest: true, bufferingPolicy: .bufferingNewest(1), initialElement: 0)

        var initialIterator = broadcast.makeStream().makeAsyncIterator()
        let initial = await initialIterator.next()
        XCTAssertEqual(initial, 0)

        broadcast.send(5)

        var laterIterator = broadcast.makeStream().makeAsyncIterator()
        let replayed = await laterIterator.next()
        XCTAssertEqual(replayed, 5)
    }

    func testTerminatedStreamStopsReceiving() async throws {
        let broadcast = AsyncBroadcast<Int>(replaysLatest: false, bufferingPolicy: .unbounded)
        let stream = broadcast.makeStream()

        let task = Task {
            for await _ in stream {}
        }

        task.cancel()
        _ = await task.value

        // After termination, sending must not crash and other streams still work.
        let liveStream = broadcast.makeStream()
        broadcast.send(9)

        var iterator = liveStream.makeAsyncIterator()
        let element = await iterator.next()
        XCTAssertEqual(element, 9)
    }
}
