import XCTest
import CSoundUDSP

final class LimiterTests: XCTestCase {
    func testLimiterNeverExceedsCeilingOnPlus12dBBurst() {
        let sampleRate = 48000.0
        let block = 512
        let totalFrames = Int(sampleRate)
        let mix = TestMixState(sampleRate: sampleRate)
        su_slot_configure(mix.state, 0, 0, 1.0, 0)
        su_slot_set(mix.state, 0, 2.0, 0)

        let input = TestBufferList(buffers: 1, channelsPerBuffer: 2, frames: block)
        let output = TestBufferList(buffers: 1, channelsPerBuffer: 2, frames: block)
        var outL: [Float] = []
        outL.reserveCapacity(totalFrames)
        var maxAbs: Float = 0
        var frame = 0
        while frame < totalFrames {
            let inSamples = input.samples(0)
            for i in 0..<block {
                let v = Float(0.9 * sin(2 * Double.pi * 440 * Double(frame + i) / sampleRate))
                inSamples[2 * i] = v
                inSamples[2 * i + 1] = v
            }
            mix.render(input, output, frames: block)
            for (i, s) in output.samples(0).enumerated() {
                maxAbs = max(maxAbs, abs(s))
                if i % 2 == 0 { outL.append(s) }
            }
            frame += block
        }

        XCTAssertLessThanOrEqual(maxAbs, 0.995)
        let tail = outL.suffix(totalFrames / 2)
        let rms = sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))
        XCTAssertGreaterThanOrEqual(rms, 0.6)
    }

    func testProcessClampsInstantlyAndLeavesQuietSignalAlone() {
        var limiter = SULimiter()
        su_limiter_init(&limiter, 48000)
        var loud: [Float] = [1.8, -1.8, 0.5, -0.5]
        su_limiter_process_stereo(&limiter, &loud, 2)
        XCTAssertLessThanOrEqual(abs(loud[0]), 0.995)
        XCTAssertLessThanOrEqual(abs(loud[1]), 0.995)

        var fresh = SULimiter()
        su_limiter_init(&fresh, 48000)
        var quiet: [Float] = [0.5, -0.25, 0.9, 0.1]
        let original = quiet
        su_limiter_process_stereo(&fresh, &quiet, 2)
        XCTAssertEqual(quiet, original)
    }
}
