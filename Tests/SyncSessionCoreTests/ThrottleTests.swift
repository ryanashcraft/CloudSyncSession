import SyncSessionCore
import XCTest

final class ThrottleTests: XCTestCase {
    func testStartsAtTheFloor() {
        XCTAssertEqual(Throttle().duration, Throttle.minDuration)
        XCTAssertEqual(Throttle.minDuration, 0.25)
        XCTAssertEqual(Throttle.maxDuration, 600)
    }

    // MARK: No pressure

    func testNoPressureShrinksTheDurationByAThird() {
        var throttle = Throttle()
        throttle.record(.waitRequested(9))

        throttle.record(.noPressure)
        XCTAssertEqual(throttle.duration, 6, accuracy: 1e-9)

        throttle.record(.noPressure)
        XCTAssertEqual(throttle.duration, 4, accuracy: 1e-9)
    }

    func testNoPressureDoesNotShrinkTheDurationBelowTheFloor() {
        var throttle = Throttle()
        throttle.record(.waitRequested(0.3))

        // Two thirds of 0.3 is 0.2, which is under the floor.
        throttle.record(.noPressure)
        XCTAssertEqual(throttle.duration, Throttle.minDuration)

        throttle.record(.noPressure)
        XCTAssertEqual(throttle.duration, Throttle.minDuration)
    }

    // MARK: Pressure

    func testPressureDoublesTheDuration() {
        var throttle = Throttle()

        throttle.record(.pressure)
        XCTAssertEqual(throttle.duration, 0.5)

        throttle.record(.pressure)
        XCTAssertEqual(throttle.duration, 1)

        throttle.record(.pressure)
        XCTAssertEqual(throttle.duration, 2)
    }

    func testPressureDoesNotGrowTheDurationPastTheCap() {
        var throttle = Throttle()

        // 0.25 s doubled twelve times is 1,024 s.
        for _ in 0 ..< 12 {
            throttle.record(.pressure)
        }

        XCTAssertEqual(throttle.duration, Throttle.maxDuration)

        throttle.record(.pressure)
        XCTAssertEqual(throttle.duration, Throttle.maxDuration)
    }

    /// The defect this type replaces: a controller whose internal number kept falling with each
    /// success, far below the floor it was clamped to, so that after a long quiet run dozens of
    /// failures had to arrive before the gap between requests moved at all.
    func testALongRunOfSuccessesDoesNotDelayTheResponseToPressure() {
        var fresh = Throttle()
        var seasoned = Throttle()

        for _ in 0 ..< 1000 {
            seasoned.record(.noPressure)
        }

        XCTAssertEqual(seasoned, fresh)

        fresh.record(.pressure)
        seasoned.record(.pressure)

        XCTAssertEqual(seasoned.duration, 0.5)
        XCTAssertEqual(seasoned, fresh)
    }

    // MARK: A wait the server asked for

    func testARequestedWaitBecomesTheDuration() {
        var throttle = Throttle()

        throttle.record(.waitRequested(30))

        XCTAssertEqual(throttle.duration, 30)
    }

    func testARequestedWaitReplacesALongerDuration() {
        var throttle = Throttle()

        for _ in 0 ..< 8 {
            throttle.record(.pressure)
        }

        XCTAssertEqual(throttle.duration, 64)

        throttle.record(.waitRequested(5))

        XCTAssertEqual(throttle.duration, 5)
    }

    func testARequestedWaitIsCapped() {
        var throttle = Throttle()

        throttle.record(.waitRequested(60 * 60))

        XCTAssertEqual(throttle.duration, Throttle.maxDuration)
    }

    func testARequestedWaitShorterThanTheFloorIsRaisedToTheFloor() {
        var throttle = Throttle()

        throttle.record(.waitRequested(0))

        XCTAssertEqual(throttle.duration, Throttle.minDuration)
    }

    /// Doubling zero gives zero, so a duration allowed to reach zero would never grow again.
    func testPressureStillGrowsTheDurationAfterARequestedWaitOfZero() {
        var throttle = Throttle()

        throttle.record(.waitRequested(0))
        throttle.record(.pressure)

        XCTAssertEqual(throttle.duration, 0.5)
    }
}
