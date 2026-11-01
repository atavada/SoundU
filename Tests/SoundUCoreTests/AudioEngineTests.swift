import CoreAudio
import Foundation
import XCTest
@testable import SoundUCore

@MainActor
final class AudioEngineTests: XCTestCase {
    // MARK: - Fixtures

    private let speakers = OutputDevice(id: 10, uid: "speakers", name: "MacBook Speakers",
                                        sampleRate: 48_000, outputChannels: 2, transport: 0)
    private let airPods = OutputDevice(id: 20, uid: "airpods", name: "AirPods",
                                       sampleRate: 48_000, outputChannels: 2, transport: 0)

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [EngineEvent] = []
        var events: [EngineEvent] { lock.lock(); defer { lock.unlock() }; return _events }
        func append(_ e: EngineEvent) { lock.lock(); _events.append(e); lock.unlock() }
    }

    private func makeEngine(ioTimeout: Duration = .seconds(60))
        -> (AudioEngine, FakeAudioSystem, EventLog) {
        let fake = FakeAudioSystem()
        fake.devices = [speakers, airPods]
        fake.defaultUID = "speakers"
        let engine = AudioEngine(system: fake, ioTimeout: ioTimeout)
        let log = EventLog()
        engine.onEvent = { log.append($0) }
        return (engine, fake, log)
    }

    private func spec(_ appID: String, _ ids: AudioObjectID...) -> TapSpec {
        TapSpec(appID: appID, processObjectIDs: ids)
    }

    private func plan(_ byDevice: [String: [TapSpec]]) -> RoutingPlan {
        RoutingPlan(byDevice: byDevice, excluded: [:])
    }

    private func tapName(_ appID: String) -> String { "SoundU-\(getpid())-\(appID)" }

    private func aggregates(_ calls: [FakeAudioSystem.Call]) -> [String] {
        calls.compactMap { if case .createAggregate(let uid, _) = $0 { return uid } else { return nil } }
    }

    private func aggregateTapUIDs(_ calls: [FakeAudioSystem.Call]) -> [[String]] {
        calls.compactMap { if case .createAggregate(_, let uids) = $0 { return uids } else { return nil } }
    }

    private func createdTaps(_ calls: [FakeAudioSystem.Call]) -> [String] {
        calls.compactMap { if case .createTap(_, let name) = $0 { return name } else { return nil } }
    }

    /// Runs `cycles` IO callbacks on `agg`, each with one constant-valued interleaved stereo
    /// input buffer per entry of `inputs`, and returns the left sample of the last output frame.
    private func render(_ fake: FakeAudioSystem, _ agg: AudioObjectID, inputs: [Float],
                        frames: Int = 64, cycles: Int = 1) -> Float {
        let input = AudioBufferList.allocate(maximumBuffers: max(inputs.count, 1))
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        var storage: [UnsafeMutablePointer<Float>] = []
        defer {
            storage.forEach { $0.deallocate() }
            free(input.unsafeMutablePointer)
            free(output.unsafeMutablePointer)
        }
        func buffer(_ value: Float) -> AudioBuffer {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            data.initialize(repeating: value, count: frames * 2)
            storage.append(data)
            return AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 2 * 4), mData: data)
        }
        input.count = inputs.count
        for (i, value) in inputs.enumerated() { input[i] = buffer(value) }
        output[0] = buffer(0)
        for _ in 0..<cycles {
            fake.invokeIO(aggregate: agg, input: input.unsafePointer, output: output.unsafeMutablePointer)
        }
        return output[0].mData!.assumingMemoryBound(to: Float.self)[(frames - 1) * 2]
    }

    // MARK: - Tests

    func testNewDeviceCreatesTapsAndOneAggregate() throws {
        let (engine, fake, log) = makeEngine()
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2, 3)]]))

        let calls = fake.calls
        XCTAssertEqual(createdTaps(calls), [tapName("A"), tapName("B")])
        XCTAssertTrue(calls.contains(.createTap(processObjectIDs: [2, 3], name: tapName("B"))))
        XCTAssertEqual(aggregates(calls), ["speakers"])
        XCTAssertEqual(aggregateTapUIDs(calls).first?.count, 2)
        let agg = try XCTUnwrap(engine.runningAggregates["speakers"])
        XCTAssertTrue(calls.contains(.setBufferFrameSize(agg, 128)))
        XCTAssertEqual(calls.last, .startIO(aggregate: agg))
        XCTAssertEqual(fake.activeIOCount, 1)
        XCTAssertEqual(log.events, [.deviceStarted(uid: "speakers", addedLatencyMs: 10)])

        // Tap order in the aggregate is the input buffer index: A reads buffer 0, B buffer 1.
        engine.set(appID: "B", volume: 0, muted: false)
        XCTAssertEqual(render(fake, agg, inputs: [0.1, 0.3], cycles: 20), 0.1, accuracy: 1e-6)

        // Re-applying the same plan changes nothing.
        let before = fake.calls.count
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2, 3)]]))
        XCTAssertEqual(fake.calls.count, before)
    }

    /// Review Focus 5: Chrome helper processes come and go; only Chrome's tap is replaced, in place.
    func testTapChangeUpdatesTapListWithoutRecreatingAggregate() throws {
        let (engine, fake, _) = makeEngine()
        engine.apply(plan(["speakers": [spec("A", 1), spec("Chrome", 2), spec("C", 3)]]))
        let agg = try XCTUnwrap(engine.runningAggregates["speakers"])
        let oldUIDs = try XCTUnwrap(aggregateTapUIDs(fake.calls).first)
        let mark = fake.calls.count

        engine.apply(plan(["speakers": [spec("A", 1), spec("Chrome", 2, 4), spec("C", 3)]]))

        let calls = Array(fake.calls[mark...])
        XCTAssertEqual(calls.count, 3, "\(calls)")
        XCTAssertEqual(calls[0], .createTap(processObjectIDs: [2, 4], name: tapName("Chrome")))
        guard case .setAggregateTaps(let a, let uids) = calls[1] else { return XCTFail("\(calls)") }
        XCTAssertEqual(a, agg)
        XCTAssertEqual(uids.count, 3)
        XCTAssertEqual(uids[0], oldUIDs[0])
        XCTAssertNotEqual(uids[1], oldUIDs[1])
        XCTAssertEqual(uids[2], oldUIDs[2])
        guard case .destroyTap = calls[2] else { return XCTFail("\(calls)") }
        XCTAssertEqual(engine.runningAggregates["speakers"], agg)
        XCTAssertEqual(fake.activeIOCount, 1)

        // Removing Chrome shifts C from buffer 2 to buffer 1; C must follow its buffer.
        engine.set(appID: "C", volume: 0.5, muted: false)
        engine.apply(plan(["speakers": [spec("A", 1), spec("C", 3)]]))
        XCTAssertEqual(engine.runningAggregates["speakers"], agg)
        XCTAssertEqual(aggregates(fake.calls).count, 1)
        XCTAssertEqual(render(fake, agg, inputs: [0.1, 0.3], cycles: 20), 0.25, accuracy: 1e-5)
    }

    /// While the HAL switches to a shifted tap list, no slot may read another app's buffer:
    /// slots whose buffer index changes are off before the change (a short gap instead).
    func testShiftedTapListNeverRendersAnotherAppsBuffer() throws {
        let (engine, fake, _) = makeEngine()
        engine.set(appID: "A", volume: 0, muted: false)
        engine.set(appID: "Chrome", volume: 1, muted: false)
        engine.set(appID: "C", volume: 0.5, muted: false)
        engine.apply(plan(["speakers": [spec("A", 1), spec("Chrome", 2), spec("C", 3)]]))
        let agg = try XCTUnwrap(engine.runningAggregates["speakers"])
        XCTAssertEqual(render(fake, agg, inputs: [0, 0.2, 0.3], cycles: 20), 0.35, accuracy: 1e-5)

        // Chrome leaves: the HAL now delivers C's audio in buffer 1, Chrome's old buffer.
        var during: Float?
        fake.onSetAggregateTaps = { agg in
            MainActor.assumeIsolated { during = self.render(fake, agg, inputs: [0, 0.3]) }
        }
        engine.apply(plan(["speakers": [spec("A", 1), spec("C", 3)]]))

        XCTAssertEqual(during ?? -1, 0, accuracy: 1e-6, "C's audio must not play at Chrome's gain")
        XCTAssertEqual(render(fake, agg, inputs: [0, 0.3], cycles: 20), 0.15, accuracy: 1e-5)
    }

    /// A failed tap-list change must not leave the old list (e.g. a call app) tapped.
    func testFailedTapListChangeTearsDownGraph() throws {
        let (engine, fake, _) = makeEngine()
        engine.apply(plan(["speakers": [spec("A", 1), spec("Call", 2)]]))
        let agg = try XCTUnwrap(engine.runningAggregates["speakers"])
        let mark = fake.calls.count
        fake.failSetAggregateTaps = true

        engine.apply(plan(["speakers": [spec("A", 1)]]))

        let calls = Array(fake.calls[mark...])
        XCTAssertNil(engine.runningAggregates["speakers"], "graph stopped: its apps play directly")
        XCTAssertTrue(calls.contains(.stopIO(aggregate: agg)))
        XCTAssertTrue(calls.contains(.destroyAggregate(agg)))
        XCTAssertEqual(calls.filter { if case .destroyTap = $0 { true } else { false } }.count, 2,
                       "both old taps destroyed, the call app's included")
        XCTAssertEqual(fake.activeIOCount, 0)
    }

    /// The physical device's own input streams come first in the aggregate's input buffers.
    func testDeviceInputStreamsOffsetTapBuffers() throws {
        let (engine, fake, _) = makeEngine()
        fake.deviceInputStreams = ["speakers": 1]
        engine.set(appID: "B", volume: 0.5, muted: false)
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2)]]))
        let agg = try XCTUnwrap(engine.runningAggregates["speakers"])
        // Buffer 0 is the microphone and must never be mixed: A = 0.1, B = 0.4 * 0.5.
        XCTAssertEqual(render(fake, agg, inputs: [0.9, 0.1, 0.4]), 0.3, accuracy: 1e-6)

        // After a tap-list change the offset still applies (C appended at buffer 3).
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2), spec("C", 3)]]))
        XCTAssertEqual(render(fake, agg, inputs: [0.9, 0.1, 0.4, 0.05]), 0.35, accuracy: 1e-6)

        // Removing A shifts B and C down; the mic stays out.
        engine.apply(plan(["speakers": [spec("B", 2), spec("C", 3)]]))
        XCTAssertEqual(render(fake, agg, inputs: [0.9, 0.4, 0.05]), 0.25, accuracy: 1e-6)
    }

    /// Finding 7: the device's own input streams (a headset mic) are switched off for our
    /// IOProc before IO starts and after every tap-list change; only tap streams stay on.
    func testDeviceInputStreamsAreDisabledForTheIOProc() throws {
        let (engine, fake, _) = makeEngine()
        fake.deviceInputStreams = ["speakers": 2]
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2)]]))
        let agg = try XCTUnwrap(engine.runningAggregates["speakers"])
        XCTAssertEqual(Array(fake.calls.suffix(2)),
                       [.setInputStreamUsage(agg, [false, false, true, true]), .startIO(aggregate: agg)])

        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2), spec("C", 3)]]))
        XCTAssertEqual(fake.calls.last { if case .setInputStreamUsage = $0 { true } else { false } },
                       .setInputStreamUsage(agg, [false, false, true, true, true]))

        // A device with no input streams: nothing to disable, no usage call.
        engine.apply(plan(["airpods": [spec("D", 4)]]))
        let aggA = try XCTUnwrap(engine.runningAggregates["airpods"])
        XCTAssertFalse(fake.calls.contains { if case .setInputStreamUsage(aggA, _) = $0 { true } else { false } })
    }

    func testTapFailureLeavesAppUntappedAndReports() throws {
        let (engine, fake, log) = makeEngine()
        fake.failingTapNames = [tapName("B")]
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2)]]))

        XCTAssertEqual(aggregateTapUIDs(fake.calls).map(\.count), [1])
        guard case .tapFailed(let appID, _) = log.events.first else { return XCTFail("\(log.events)") }
        XCTAssertEqual(appID, "B")
        XCTAssertEqual(engine.takePeaks().keys.sorted(), ["A"])

        // Every tap fails: no aggregate at all.
        fake.failingTapNames = [tapName("D")]
        engine.apply(plan(["speakers": [spec("A", 1)], "airpods": [spec("D", 4)]]))
        XCTAssertEqual(aggregates(fake.calls), ["speakers"])
        XCTAssertNil(engine.runningAggregates["airpods"])
    }

    func testAggregateFailureDestroysTapsAndReports() {
        let (engine, fake, log) = makeEngine()
        fake.failingAggregateDeviceUIDs = ["speakers"]
        engine.apply(plan(["speakers": [spec("A", 1)]]))

        XCTAssertEqual(fake.calls.filter { if case .destroyTap = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(fake.activeIOCount, 0)
        XCTAssertTrue(engine.runningAggregates.isEmpty)
        guard case .tapFailed(let appID, _) = log.events.first else { return XCTFail("\(log.events)") }
        XCTAssertEqual(appID, "A")
    }

    func testDeviceRemovedTearsDown() throws {
        let (engine, fake, _) = makeEngine()
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2)], "airpods": [spec("C", 3)]]))
        let aggS = try XCTUnwrap(engine.runningAggregates["speakers"])
        let aggA = try XCTUnwrap(engine.runningAggregates["airpods"])
        let mark = fake.calls.count

        engine.apply(plan(["airpods": [spec("C", 3)]]))

        let calls = Array(fake.calls[mark...])
        XCTAssertEqual(calls.first, .stopIO(aggregate: aggS))
        XCTAssertEqual(calls.dropFirst().first, .destroyAggregate(aggS))
        XCTAssertEqual(calls.dropFirst(2).filter { if case .destroyTap = $0 { true } else { false } }.count, 2)
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(engine.runningAggregates, ["airpods": aggA])
        XCTAssertEqual(fake.activeIOCount, 1)

        engine.stopAll()
        XCTAssertTrue(engine.runningAggregates.isEmpty)
        XCTAssertEqual(fake.activeIOCount, 0)
        XCTAssertTrue(fake.calls.contains(.destroyAggregate(aggA)))
    }

    func testSetVolumeDoesNotTouchHAL() throws {
        let (engine, fake, _) = makeEngine()
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        let agg = try XCTUnwrap(engine.runningAggregates["speakers"])
        XCTAssertEqual(render(fake, agg, inputs: [0.1]), 0.1, accuracy: 1e-6)
        let calls = fake.calls

        engine.set(appID: "A", volume: 0.5, muted: false)
        XCTAssertEqual(render(fake, agg, inputs: [0.1], cycles: 20), 0.05, accuracy: 1e-6)
        engine.set(appID: "A", volume: 0.5, muted: true)
        XCTAssertEqual(render(fake, agg, inputs: [0.1], cycles: 20), 0, accuracy: 1e-6) // past the mute ramp
        engine.set(appID: "Unknown", volume: 2, muted: false)

        XCTAssertEqual(fake.calls, calls)
        XCTAssertEqual(engine.takePeaks()["A"] ?? -1, 0.1, accuracy: 1e-6)
        XCTAssertEqual(engine.takePeaks()["A"], 0)

        // A remembered volume applies when the app is (re)tapped.
        engine.set(appID: "B", volume: 0.5, muted: false)
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2)]]))
        XCTAssertEqual(render(fake, agg, inputs: [0, 0.4]), 0.2, accuracy: 1e-6)
    }

    func testExemptAppliedToEveryGraphAndOnStart() throws {
        let (engine, fake, _) = makeEngine()
        engine.setDuckingExempt(true)
        XCTAssertTrue(fake.calls.isEmpty)

        engine.apply(plan(["speakers": [spec("A", 1)], "airpods": [spec("B", 2)]]))
        let aggS = try XCTUnwrap(engine.runningAggregates["speakers"])
        let aggA = try XCTUnwrap(engine.runningAggregates["airpods"])
        XCTAssertTrue(fake.calls.contains(.setNoDuck(aggS, true)))
        XCTAssertTrue(fake.calls.contains(.setNoDuck(aggA, true)))

        var mark = fake.calls.count
        engine.setDuckingExempt(false)
        XCTAssertEqual(Set(fake.calls[mark...].map { "\($0)" }),
                       Set([FakeAudioSystem.Call.setNoDuck(aggS, false), .setNoDuck(aggA, false)].map { "\($0)" }))

        engine.setDuckingExempt(true)
        mark = fake.calls.count
        engine.apply(plan(["airpods": [spec("B", 2)]]))
        let stop = Array(fake.calls[mark...])
        XCTAssertEqual(Array(stop.prefix(3)), [.stopIO(aggregate: aggS), .setNoDuck(aggS, false), .destroyAggregate(aggS)])

        // 'nodk' failing falls back to AudioDeviceDuck on the physical device.
        var ducked: [(AudioObjectID, Bool)] = []
        engine.duckFallback = { ducked.append(($0, $1)) }
        fake.noDuckSucceeds = false
        engine.setDuckingExempt(false)
        engine.setDuckingExempt(true)
        XCTAssertEqual(ducked.map(\.0), [20, 20])
        XCTAssertEqual(ducked.map(\.1), [false, true])
    }

    /// Manual clock for the IO watchdog.
    private final class Clock {
        var now = ContinuousClock.now
        func advance(_ d: Duration) { now += d }
    }

    private func watched(_ engine: AudioEngine) -> Clock {
        let clock = Clock()
        engine.now = { clock.now }
        return clock
    }

    private let bluetooth = OutputDevice(id: 30, uid: "bt", name: "Headset", sampleRate: 48_000,
                                         outputChannels: 2, transport: kAudioDeviceTransportTypeBluetooth)

    /// Review Focus 1: no IO callbacks (permission not granted) → report, untap, keep apps playing.
    func testFrozenFromStartReportsPermissionPendingAndUntaps() throws {
        let (engine, fake, log) = makeEngine(ioTimeout: .seconds(2))
        let clock = watched(engine)
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        let agg = try XCTUnwrap(engine.runningAggregates["speakers"])

        clock.advance(.seconds(1.5))
        engine.checkIO()
        XCTAssertEqual(engine.runningAggregates["speakers"], agg, "not yet 2 s")

        clock.advance(.seconds(0.6))
        engine.checkIO()

        XCTAssertEqual(log.events.last, .permissionPending)
        XCTAssertTrue(engine.permissionPending)
        XCTAssertTrue(fake.calls.contains(.stopIO(aggregate: agg)))
        XCTAssertTrue(fake.calls.contains(.destroyAggregate(agg)))
        XCTAssertTrue(fake.calls.contains { if case .destroyTap = $0 { true } else { false } })
        XCTAssertEqual(fake.activeIOCount, 0)
        XCTAssertTrue(engine.runningAggregates.isEmpty)

        // While pending, apply does not tap again; once the controller clears the flag it retries.
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        XCTAssertEqual(aggregates(fake.calls).count, 1)
        engine.permissionPending = false
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        XCTAssertEqual(aggregates(fake.calls).count, 2)
        engine.stopAll()
    }

    /// Bluetooth devices can take longer to start: one extra period before `.permissionPending`.
    func testBluetoothGetsOneExtraPeriodBeforePermissionPending() throws {
        let (engine, fake, log) = makeEngine(ioTimeout: .seconds(2))
        fake.devices = [speakers, bluetooth]
        let clock = watched(engine)
        engine.apply(plan(["bt": [spec("A", 1)]]))

        clock.advance(.seconds(3.9))
        engine.checkIO()
        XCTAssertNotNil(engine.runningAggregates["bt"], "within 2 x 2 s")
        XCTAssertFalse(log.events.contains(.permissionPending))

        clock.advance(.seconds(0.2))
        engine.checkIO()
        XCTAssertEqual(log.events.last, .permissionPending)
        XCTAssertNil(engine.runningAggregates["bt"])
    }

    /// `.granted` comes from seeing IO, not from starting a device; confirmed once per run.
    func testCallbacksConfirmIOOnce() throws {
        let (engine, fake, log) = makeEngine(ioTimeout: .seconds(2))
        let clock = watched(engine)
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        let agg = try XCTUnwrap(engine.runningAggregates["speakers"])
        engine.checkIO()
        XCTAssertFalse(log.events.contains(.ioConfirmed(uid: "speakers")), "no callbacks yet")

        for _ in 0..<5 { // IO keeps running: never stalled
            fake.invokeIO(aggregate: agg)
            clock.advance(.seconds(1))
            engine.checkIO()
        }

        XCTAssertEqual(log.events.filter { $0 == .ioConfirmed(uid: "speakers") }.count, 1)
        XCTAssertFalse(engine.permissionPending)
        XCTAssertEqual(engine.runningAggregates["speakers"], agg)

        // Once confirmed, a later graph that never runs is a stall, not a permission problem.
        engine.apply(plan(["speakers": [spec("A", 1)], "airpods": [spec("B", 2)]]))
        clock.advance(.seconds(2.1))
        fake.invokeIO(aggregate: agg)
        engine.checkIO()
        XCTAssertEqual(log.events.last, .ioStalled(uid: "airpods"))
        XCTAssertFalse(engine.permissionPending)
        engine.stopAll()
    }

    /// IO that stops advancing after it ran: torn down, reported, retried after a 5 s back-off.
    func testFrozenAfterStartReportsStallAndBacksOff() throws {
        let (engine, fake, log) = makeEngine(ioTimeout: .seconds(2))
        let clock = watched(engine)
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        let agg = try XCTUnwrap(engine.runningAggregates["speakers"])
        fake.invokeIO(aggregate: agg)
        engine.checkIO()

        clock.advance(.seconds(2.1))
        engine.checkIO()

        XCTAssertEqual(log.events.last, .ioStalled(uid: "speakers"))
        XCTAssertFalse(engine.permissionPending)
        XCTAssertNil(engine.runningAggregates["speakers"], "torn down: the app plays directly")
        XCTAssertEqual(fake.activeIOCount, 0)
        XCTAssertEqual(engine.stalledDevices, ["speakers"])

        engine.apply(plan(["speakers": [spec("A", 1)]]))
        XCTAssertNil(engine.runningAggregates["speakers"], "backing off")
        clock.advance(.seconds(5))
        XCTAssertEqual(engine.stalledDevices, [])
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        XCTAssertNotNil(engine.runningAggregates["speakers"], "retried after 5 s")
        engine.stopAll()
    }
}
