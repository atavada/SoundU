import XCTest
@testable import SoundUCore

final class FaderMathTests: XCTestCase {
    func testDetentAtTwoThirds() {
        XCTAssertEqual(FaderMath.position(forValue: 1, ceiling: 2), 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(FaderMath.value(forPosition: 2.0 / 3, ceiling: 2), 1, accuracy: 1e-6)
    }

    func testRoundTripValues() {
        for v: Float in [0, 0.5, 1, 1.5, 2] {
            let p = FaderMath.position(forValue: v, ceiling: 2)
            XCTAssertEqual(FaderMath.value(forPosition: p, ceiling: 2), v, accuracy: 1e-5, "value \(v)")
        }
        XCTAssertEqual(FaderMath.position(forValue: 0, ceiling: 2), 0, accuracy: 1e-9)
        XCTAssertEqual(FaderMath.position(forValue: 2, ceiling: 2), 1, accuracy: 1e-9)
    }

    func testSnapNearUnity() {
        XCTAssertEqual(FaderMath.snapped(0.98), 1.0)
        XCTAssertEqual(FaderMath.snapped(1.02), 1.0)
        XCTAssertEqual(FaderMath.snapped(0.95), 0.95)
        XCTAssertEqual(FaderMath.snapped(1.5), 1.5)
    }

    func testCeilingLimitsTop() {
        XCTAssertEqual(FaderMath.value(forPosition: 1.0, ceiling: 1.5), 1.5, accuracy: 1e-6)
        XCTAssertEqual(FaderMath.position(forValue: 1.5, ceiling: 1.5), 1.0, accuracy: 1e-9)
        // Values above the ceiling pin to the top; no boost zone at ceiling 1.0.
        XCTAssertEqual(FaderMath.position(forValue: 2, ceiling: 1.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(FaderMath.value(forPosition: 1.0, ceiling: 1.0), 1.0, accuracy: 1e-6)
    }

    func testOptionScrollIsFine() {
        XCTAssertEqual(FaderMath.fineStep(1.0, deltaY: 1, option: true), 1.01, accuracy: 1e-6)
        XCTAssertEqual(FaderMath.fineStep(1.0, deltaY: -1, option: true), 0.99, accuracy: 1e-6)
        XCTAssertEqual(FaderMath.fineStep(1.0, deltaY: 1, option: false), 1.05, accuracy: 1e-6)
        XCTAssertEqual(FaderMath.fineStep(0.02, deltaY: -1, option: false), 0, accuracy: 1e-6)
        XCTAssertEqual(FaderMath.fineStep(0.5, deltaY: 0, option: false), 0.5)
    }
}
