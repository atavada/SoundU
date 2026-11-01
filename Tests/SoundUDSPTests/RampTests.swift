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

    func testNonUnityApplyRampsBothChannelsPerFrame() {
        var r = SURamp()
        su_ramp_init(&r, 1.0, 48000)
        let step = Float(1.0 / (0.010 * 48000.0))
        let frames = 600
        var buffer = [Float](repeating: 1.0, count: frames * 2)
        su_ramp_apply_stereo(&r, 0.0, &buffer, UInt32(frames))
        for i in 0..<frames {
            XCTAssertEqual(buffer[2 * i], buffer[2 * i + 1], "L/R differ at frame \(i)")
            let expected = max(0, 1.0 - Float(i + 1) * step)
            XCTAssertEqual(buffer[2 * i], expected, accuracy: 1e-4, "frame \(i)")
        }
        XCTAssertEqual(buffer[2 * (frames - 1)], 0)
        XCTAssertEqual(r.current, 0)
    }
}
