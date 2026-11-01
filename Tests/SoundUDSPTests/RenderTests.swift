import XCTest
import CSoundUDSP

final class RenderTests: XCTestCase {
    let frames = 256

    func testMixSumsTwoSlotsAtUnity() {
        let mix = TestMixState()
        su_slot_configure(mix.state, 0, 0, 1.0, 0)
        su_slot_configure(mix.state, 1, 1, 1.0, 0)
        let input = TestBufferList(buffers: 2, channelsPerBuffer: 2, frames: frames)
        input.samples(0).update(repeating: 0.25)
        input.samples(1).update(repeating: 0.5)
        let output = TestBufferList(buffers: 1, channelsPerBuffer: 2, frames: frames)

        mix.render(input, output, frames: frames)

        XCTAssertTrue(output.samples(0).allSatisfy { $0 == 0.75 })
    }

    func testMutedSlotOutputsZeroButReportsNoPeak() {
        let mix = TestMixState()
        su_slot_configure(mix.state, 0, 0, 1.0, 1)
        let input = TestBufferList(buffers: 1, channelsPerBuffer: 2, frames: frames)
        input.samples(0).update(repeating: 0.5)
        let output = TestBufferList(buffers: 1, channelsPerBuffer: 2, frames: frames)
        output.samples(0).update(repeating: 0.3)

        mix.render(input, output, frames: frames)

        XCTAssertTrue(output.samples(0).allSatisfy { $0 == 0 })
        XCTAssertEqual(su_slot_take_peak(mix.state, 0), 0)
    }

    /// Mute ramps to 0 over the 10 ms slope (no click) and then outputs exact silence.
    func testMuteRampsDownWithoutStepsAndReachesZero() {
        let mix = TestMixState()
        su_slot_configure(mix.state, 0, 0, 1.0, 0)
        let input = TestBufferList(buffers: 1, channelsPerBuffer: 2, frames: frames)
        input.samples(0).update(repeating: 0.5)
        let output = TestBufferList(buffers: 1, channelsPerBuffer: 2, frames: frames)
        mix.render(input, output, frames: frames)
        var previous = output.samples(0)[2 * (frames - 1)]
        XCTAssertEqual(previous, 0.5)

        su_slot_set(mix.state, 0, 1.0, 1)
        let maxStep = 0.5 / Float(0.010 * 48000) + 1e-6 // input x one ramp step
        for block in 0..<4 { // 1024 frames > the 480-frame ramp
            mix.render(input, output, frames: frames)
            let out = output.samples(0)
            for f in 0..<frames {
                XCTAssertLessThanOrEqual(abs(out[2 * f] - previous), maxStep, "block \(block) frame \(f)")
                previous = out[2 * f]
            }
        }
        XCTAssertTrue(output.samples(0).allSatisfy { $0 == 0 }, "exact silence once the ramp ends")
        _ = su_slot_take_peak(mix.state, 0)
        mix.render(input, output, frames: frames)
        XCTAssertEqual(su_slot_take_peak(mix.state, 0), 0, "a fully muted slot is skipped")
    }

    func testSixChannelNonInterleavedGetsStereoOnFirstTwo() {
        let mix = TestMixState()
        su_slot_configure(mix.state, 0, 0, 1.0, 0)
        let input = TestBufferList(buffers: 1, channelsPerBuffer: 2, frames: frames)
        let inSamples = input.samples(0)
        for i in 0..<frames {
            inSamples[2 * i] = Float(i) / Float(frames) * 0.8
            inSamples[2 * i + 1] = -Float(i) / Float(frames) * 0.6
        }
        let output = TestBufferList(buffers: 6, channelsPerBuffer: 1, frames: frames)
        for b in 0..<6 { output.samples(b).update(repeating: 0.3) }

        mix.render(input, output, frames: frames)

        for i in 0..<frames {
            XCTAssertEqual(output.samples(0)[i], inSamples[2 * i])
            XCTAssertEqual(output.samples(1)[i], inSamples[2 * i + 1])
        }
        for b in 2..<6 {
            XCTAssertTrue(output.samples(b).allSatisfy { $0 == 0 }, "buffer \(b) not silent")
        }
    }

    func testInterleavedFourChannel() {
        let mix = TestMixState()
        su_slot_configure(mix.state, 0, 0, 1.0, 0)
        let input = TestBufferList(buffers: 1, channelsPerBuffer: 2, frames: frames)
        let inSamples = input.samples(0)
        for i in 0..<frames {
            inSamples[2 * i] = 0.4
            inSamples[2 * i + 1] = -0.2
        }
        let output = TestBufferList(buffers: 1, channelsPerBuffer: 4, frames: frames)
        output.samples(0).update(repeating: 0.3)

        mix.render(input, output, frames: frames)

        let out = output.samples(0)
        for i in 0..<frames {
            XCTAssertEqual(Array(out[(4 * i)..<(4 * i + 4)]), [0.4, -0.2, 0, 0], "frame \(i)")
        }
    }

    func testPeakIsTakenAndReset() {
        let mix = TestMixState()
        su_slot_configure(mix.state, 0, 0, 1.0, 0)
        let input = TestBufferList(buffers: 1, channelsPerBuffer: 2, frames: frames)
        input.samples(0).update(repeating: 0.5)
        input.samples(0)[7] = -0.7
        let output = TestBufferList(buffers: 1, channelsPerBuffer: 2, frames: frames)

        mix.render(input, output, frames: frames)

        XCTAssertEqual(su_slot_take_peak(mix.state, 0), 0.7)
        XCTAssertEqual(su_slot_take_peak(mix.state, 0), 0)
    }
}
