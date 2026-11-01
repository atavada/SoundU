import CoreAudio
import CSoundUDSP

/// Owns an AudioBufferList of float32 buffers for driving `su_render` in tests.
final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    let channelsPerBuffer: Int
    let frames: Int

    init(buffers: Int, channelsPerBuffer: Int, frames: Int) {
        self.channelsPerBuffer = channelsPerBuffer
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: buffers)
        for i in 0..<buffers {
            let count = channelsPerBuffer * frames
            let data = UnsafeMutablePointer<Float>.allocate(capacity: count)
            data.initialize(repeating: 0, count: count)
            list[i] = AudioBuffer(
                mNumberChannels: UInt32(channelsPerBuffer),
                mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(data)
            )
        }
    }

    deinit {
        for buffer in list {
            buffer.mData?.assumingMemoryBound(to: Float.self).deallocate()
        }
        list.unsafeMutablePointer.deallocate()
    }

    func samples(_ buffer: Int) -> UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(
            start: list[buffer].mData!.assumingMemoryBound(to: Float.self),
            count: channelsPerBuffer * frames
        )
    }
}

/// Heap-allocated `SUMixState`, as the engine will hold it.
final class TestMixState {
    let state: UnsafeMutablePointer<SUMixState>

    init(sampleRate: Double = 48000) {
        state = UnsafeMutablePointer<SUMixState>.allocate(capacity: 1)
        su_mix_init(state, sampleRate)
    }

    deinit { state.deallocate() }

    func render(_ input: TestBufferList, _ output: TestBufferList, frames: Int) {
        su_render(state, input.list.unsafePointer, output.list.unsafeMutablePointer, UInt32(frames))
    }
}
