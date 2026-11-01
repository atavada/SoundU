import XCTest
import CSoundUDSP

final class RampTests: XCTestCase {
    func testRampStepNeverExceedsTenMsSlope() {
        var r = SURamp()
        su_ramp_init(&r, 0, 48000)
        let maxStep = Float(1.0 / (0.010 * 48000.0)) + 1e-7
        var previous: Float = 0
        for _ in 0..<2000 {
            let value = su_ramp_next(&r, 2.0)
            XCTAssertLessThanOrEqual(abs(value - previous), maxStep)
            previous = value
        }
        XCTAssertEqual(previous, 2.0)
    }

    func testRampReachesUnityInTenMs() {
        var r = SURamp()
        su_ramp_init(&r, 0, 48000)
        for call in 1...480 {
            let value = su_ramp_next(&r, 1.0)
            if call < 479 {
                XCTAssertLessThan(value, 1.0, "reached 1.0 early at call \(call)")
            }
            if call == 480 {
                XCTAssertEqual(value, 1.0)
            }
        }
    }

    func testUnityApplyLeavesSamplesBitIdentical() {
        var r = SURamp()
        su_ramp_init(&r, 1.0, 48000)
        let frames: UInt32 = 512
        var buffer = (0..<Int(frames) * 2).map { _ in Float.random(in: -1...1) }
        let original = buffer
        su_ramp_apply_stereo(&r, 1.0, &buffer, frames)
        let identical = buffer.withUnsafeBytes { a in
            original.withUnsafeBytes { b in memcmp(a.baseAddress, b.baseAddress, a.count) == 0 }
        }
        XCTAssertTrue(identical)
    }
}
