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

    func testEachAppGetsItsOwnAggregate() throws {
        let (engine, fake, log) = makeEngine()
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2, 3)]]))

        let calls = fake.calls
        XCTAssertEqual(createdTaps(calls), [tapName("A"), tapName("B")])
        XCTAssertTrue(calls.contains(.createTap(processObjectIDs: [2, 3], name: tapName("B"))))
        XCTAssertEqual(aggregates(calls), ["speakers", "speakers"])
        XCTAssertEqual(aggregateTapUIDs(calls).map(\.count), [1, 1])
        let aggA = try XCTUnwrap(engine.runningAggregates[key("speakers", "A")])
        let aggB = try XCTUnwrap(engine.runningAggregates[key("speakers", "B")])
        XCTAssertNotEqual(aggA, aggB)
        XCTAssertTrue(calls.contains(.setBufferFrameSize(aggA, 128)))
        XCTAssertTrue(calls.contains(.setBufferFrameSize(aggB, 128)))
        XCTAssertEqual(calls.last, .startIO(aggregate: aggB))
        XCTAssertEqual(fake.activeIOCount, 2)
        XCTAssertEqual(log.events, [.deviceStarted(uid: "speakers", appID: "A", addedLatencyMs: 10),
                                    .deviceStarted(uid: "speakers", appID: "B", addedLatencyMs: 10)])

        // Each aggregate carries only its app's tap, at input buffer 0.
        engine.set(appID: "B", volume: 0.5, muted: false)
        XCTAssertEqual(render(fake, aggA, inputs: [0.1], cycles: 20), 0.1, accuracy: 1e-6)
        XCTAssertEqual(render(fake, aggB, inputs: [0.3], cycles: 20), 0.15, accuracy: 1e-6)

        // Re-applying the same plan changes nothing.
        let before = fake.calls.count
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2, 3)]]))
        XCTAssertEqual(fake.calls.count, before)
    }

    /// Review Focus 5: Chrome helper processes come and go; only Chrome's tap is replaced, in
    /// place on Chrome's own aggregate. Other apps' aggregates get zero HAL calls.
    func testProcessChurnTouchesOnlyThatAppsAggregate() throws {
        let (engine, fake, _) = makeEngine()
        engine.apply(plan(["speakers": [spec("A", 1), spec("Chrome", 2), spec("C", 3)]]))
        let aggA = try XCTUnwrap(engine.runningAggregates[key("speakers", "A")])
        let aggChrome = try XCTUnwrap(engine.runningAggregates[key("speakers", "Chrome")])
        let aggC = try XCTUnwrap(engine.runningAggregates[key("speakers", "C")])
        let mark = fake.calls.count

        engine.apply(plan(["speakers": [spec("A", 1), spec("Chrome", 2, 4), spec("C", 3)]]))

        let calls = Array(fake.calls[mark...])
        XCTAssertEqual(calls.count, 3, "\(calls)")
        XCTAssertEqual(calls[0], .createTap(processObjectIDs: [2, 4], name: tapName("Chrome")))
        guard case .setAggregateTaps(let a, let uids) = calls[1] else { return XCTFail("\(calls)") }
        XCTAssertEqual(a, aggChrome)
        XCTAssertEqual(uids.count, 1)
        guard case .destroyTap = calls[2] else { return XCTFail("\(calls)") }
        XCTAssertEqual(engine.runningAggregates[key("speakers", "Chrome")], aggChrome)
        XCTAssertEqual(fake.activeIOCount, 3)

        // Removing Chrome stops only Chrome's graph; A and C keep playing untouched.
        engine.set(appID: "C", volume: 0.5, muted: false)
        let stop = fake.calls.count
        engine.apply(plan(["speakers": [spec("A", 1), spec("C", 3)]]))
        XCTAssertEqual(touching(aggA, fake.calls[stop...]), [])
        XCTAssertEqual(touching(aggC, fake.calls[stop...]), [])
        XCTAssertTrue(fake.calls[stop...].contains(.destroyAggregate(aggChrome)))
        XCTAssertEqual(render(fake, aggC, inputs: [0.3], cycles: 20), 0.15, accuracy: 1e-5)
    }

    /// A failed tap-list change must not leave the app's old process set tapped (it may now
    /// include a process shared with a call): that app's graph stops, other apps' stay.
    func testFailedTapListChangeTearsDownOnlyThatAppsGraph() throws {
        let (engine, fake, _) = makeEngine()
        engine.apply(plan(["speakers": [spec("A", 1), spec("FaceTime", 2, 5)]]))
        let aggA = try XCTUnwrap(engine.runningAggregates[key("speakers", "A")])
        let agg = try XCTUnwrap(engine.runningAggregates[key("speakers", "FaceTime")])
        let mark = fake.calls.count
        fake.failSetAggregateTaps = true

        engine.apply(plan(["speakers": [spec("A", 1), spec("FaceTime", 2)]]))

        let calls = Array(fake.calls[mark...])
        XCTAssertNil(engine.runningAggregates[key("speakers", "FaceTime")], "graph stopped: the app plays directly")
        XCTAssertTrue(calls.contains(.stopIO(aggregate: agg)))
        XCTAssertTrue(calls.contains(.destroyAggregate(agg)))
        XCTAssertEqual(calls.filter { if case .destroyTap = $0 { true } else { false } }.count, 2,
                       "old and new taps destroyed")
        XCTAssertEqual(touching(aggA, calls), [])
        XCTAssertEqual(fake.activeIOCount, 1)
    }

    /// The physical device's own input streams come first in the aggregate's input buffers.
    func testDeviceInputStreamsOffsetTapBuffers() throws {
        let (engine, fake, _) = makeEngine()
        fake.deviceInputStreams = ["speakers": 1]
        engine.set(appID: "B", volume: 0.5, muted: false)
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2)]]))
        let aggA = try XCTUnwrap(engine.runningAggregates[key("speakers", "A")])
        let aggB = try XCTUnwrap(engine.runningAggregates[key("speakers", "B")])
        // Buffer 0 is the microphone and must never be mixed.
        XCTAssertEqual(render(fake, aggA, inputs: [0.9, 0.1]), 0.1, accuracy: 1e-6)
        XCTAssertEqual(render(fake, aggB, inputs: [0.9, 0.4]), 0.2, accuracy: 1e-6)

        // After a tap-list change (B's process set changed) the offset still applies.
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2, 3)]]))
        XCTAssertEqual(engine.runningAggregates[key("speakers", "B")], aggB)
        XCTAssertEqual(render(fake, aggB, inputs: [0.9, 0.4], cycles: 20), 0.2, accuracy: 1e-6)
    }

    /// Finding 7: the device's own input streams (a headset mic) are switched off for our
    /// IOProc before IO starts and after every tap-list change; only tap streams stay on.
    func testDeviceInputStreamsAreDisabledForTheIOProc() throws {
        let (engine, fake, _) = makeEngine()
        fake.deviceInputStreams = ["speakers": 2]
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        let agg = try XCTUnwrap(engine.runningAggregates[key("speakers", "A")])
        XCTAssertEqual(Array(fake.calls.suffix(2)),
                       [.setInputStreamUsage(agg, [false, false, true]), .startIO(aggregate: agg)])

        let mark = fake.calls.count
        engine.apply(plan(["speakers": [spec("A", 1, 3)]]))
        XCTAssertEqual(fake.calls[mark...].last { if case .setInputStreamUsage = $0 { true } else { false } },
                       .setInputStreamUsage(agg, [false, false, true]))

        // A device with no input streams: nothing to disable, no usage call.
        engine.apply(plan(["airpods": [spec("D", 4)]]))
        let aggA = try XCTUnwrap(engine.runningAggregates[key("airpods", "D")])
        XCTAssertFalse(fake.calls.contains { if case .setInputStreamUsage(aggA, _) = $0 { true } else { false } })
    }

    private func key(_ uid: String, _ appID: String) -> GraphKey { GraphKey(deviceUID: uid, appID: appID) }

    /// Calls that touch `agg` (tap-list changes, IO, stream usage, 'nodk', destruction).
    private func touching(_ agg: AudioObjectID, _ calls: some Sequence<FakeAudioSystem.Call>) -> [FakeAudioSystem.Call] {
        calls.filter { call in
            switch call {
            case .setAggregateTaps(let a, _), .destroyAggregate(let a), .startIO(let a), .stopIO(let a),
                 .setInputStreamUsage(let a, _), .setNoDuck(let a, _), .setBufferFrameSize(let a, _): a == agg
            default: false
            }
        }
    }

    /// 2026-11-01: a tap-list change restarts IO for every tap on an aggregate, so a new app
    /// (a notification sound) on a shared aggregate glitched every other app. Each app now has
    /// its own aggregate; starting B never touches A's.
    func testAppStartingNeverTouchesAnotherAppsAggregate() throws {
        let (engine, fake, _) = makeEngine()
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        let aggA = try XCTUnwrap(engine.runningAggregates[key("speakers", "A")])
        let mark = fake.calls.count

        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2)]]))
        let aggB = try XCTUnwrap(engine.runningAggregates[key("speakers", "B")])
        XCTAssertNotEqual(aggA, aggB)
        XCTAssertEqual(touching(aggA, fake.calls[mark...]), [], "A's aggregate untouched")
        XCTAssertEqual(aggregateTapUIDs(fake.calls).map(\.count), [1, 1], "one tap per aggregate")

        let stopB = fake.calls.count
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        XCTAssertNil(engine.runningAggregates[key("speakers", "B")])
        XCTAssertEqual(touching(aggA, fake.calls[stopB...]), [], "B stopping leaves A alone")
        XCTAssertEqual(fake.activeIOCount, 1)
    }

    /// 'nodk' is per (SoundU process, physical device): set once when the first graph on the
    /// device starts, cleared only when the last one stops.
    func testNoDuckIsReferenceCountedPerPhysicalDevice() throws {
        let (engine, fake, _) = makeEngine()
        engine.setDuckingExempt(true)
        func noDucks(from mark: Int) -> [Bool] {
            fake.calls[mark...].compactMap { if case .setNoDuck(_, let on) = $0 { on } else { nil } }
        }

        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2)]]))
        XCTAssertEqual(noDucks(from: 0), [true], "set once for the device")

        var mark = fake.calls.count
        engine.apply(plan(["speakers": [spec("B", 2)]]))
        XCTAssertEqual(noDucks(from: mark), [], "B still runs on the device")

        mark = fake.calls.count
        engine.apply(plan([:]))
        XCTAssertEqual(noDucks(from: mark), [false], "cleared exactly once with the last graph")

        // Toggling with two graphs running: one call per device each way.
        engine.setDuckingExempt(false)
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2)]]))
        mark = fake.calls.count
        engine.setDuckingExempt(true)
        XCTAssertEqual(noDucks(from: mark), [true])
        mark = fake.calls.count
        engine.setDuckingExempt(false)
        XCTAssertEqual(noDucks(from: mark), [false])
        mark = fake.calls.count
        engine.stopAll()
        XCTAssertEqual(noDucks(from: mark), [], "already cleared")
    }

    /// One app leaving while another arrives on the same device in one apply must not clear
    /// 'nodk' even briefly (a ducking window during a call).
    func testSwapOnDeviceKeepsExemptionWithoutGap() throws {
        let (engine, fake, _) = makeEngine()
        engine.setDuckingExempt(true)
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        let mark = fake.calls.count

        engine.apply(plan(["speakers": [spec("B", 2)]]))

        XCTAssertNotNil(engine.runningAggregates[key("speakers", "B")])
        XCTAssertNil(engine.runningAggregates[key("speakers", "A")])
        XCTAssertFalse(fake.calls[mark...].contains { if case .setNoDuck(_, false) = $0 { true } else { false } },
                       "\(Array(fake.calls[mark...]))")
        // Still exempt: the last graph's stop clears it exactly once.
        let stop = fake.calls.count
        engine.apply(plan([:]))
        XCTAssertEqual(fake.calls[stop...].filter { if case .setNoDuck(_, false) = $0 { true } else { false } }.count, 1)
    }

    /// The AudioDeviceDuck fallback follows the same per-device rule.
    func testDuckFallbackIsReferenceCountedPerPhysicalDevice() throws {
        let (engine, fake, _) = makeEngine()
        var ducked: [(AudioObjectID, Bool)] = []
        engine.duckFallback = { ducked.append(($0, $1)) }
        fake.noDuckSucceeds = false
        engine.setDuckingExempt(true)

        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2)]]))
        engine.apply(plan(["speakers": [spec("B", 2)]]))
        engine.apply(plan([:]))

        XCTAssertEqual(ducked.map(\.0), [10, 10])
        XCTAssertEqual(ducked.map(\.1), [true, false])
    }

    func testTapFailureLeavesAppUntappedAndReports() throws {
        let (engine, fake, log) = makeEngine()
        fake.failingTapNames = [tapName("B")]
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2)]]))

        XCTAssertEqual(aggregateTapUIDs(fake.calls).map(\.count), [1])
        let failed = log.events.compactMap { if case .tapFailed(let appID, _) = $0 { appID } else { nil } }
        XCTAssertEqual(failed, ["B"])
        XCTAssertEqual(engine.takePeaks().keys.sorted(), ["A"])

        // Every tap fails: no aggregate at all.
        fake.failingTapNames = [tapName("D")]
        engine.apply(plan(["speakers": [spec("A", 1)], "airpods": [spec("D", 4)]]))
        XCTAssertEqual(aggregates(fake.calls), ["speakers"])
        XCTAssertNil(engine.runningAggregates[key("airpods", "D")])
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
        let aggSA = try XCTUnwrap(engine.runningAggregates[key("speakers", "A")])
        let aggSB = try XCTUnwrap(engine.runningAggregates[key("speakers", "B")])
        let aggC = try XCTUnwrap(engine.runningAggregates[key("airpods", "C")])
        let mark = fake.calls.count

        engine.apply(plan(["airpods": [spec("C", 3)]]))

        let calls = Array(fake.calls[mark...])
        for agg in [aggSA, aggSB] {
            XCTAssertEqual(touching(agg, calls), [.stopIO(aggregate: agg), .destroyAggregate(agg)])
        }
        XCTAssertEqual(calls.filter { if case .destroyTap = $0 { true } else { false } }.count, 2)
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(engine.runningAggregates, [key("airpods", "C"): aggC])
        XCTAssertEqual(fake.activeIOCount, 1)

        engine.stopAll()
        XCTAssertTrue(engine.runningAggregates.isEmpty)
        XCTAssertEqual(fake.activeIOCount, 0)
        XCTAssertTrue(fake.calls.contains(.destroyAggregate(aggC)))
    }

    func testSetVolumeDoesNotTouchHAL() throws {
        let (engine, fake, _) = makeEngine()
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        let agg = try XCTUnwrap(engine.runningAggregates[key("speakers", "A")])
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
        let aggB = try XCTUnwrap(engine.runningAggregates[key("speakers", "B")])
        XCTAssertEqual(render(fake, aggB, inputs: [0.4]), 0.2, accuracy: 1e-6)
    }

    func testExemptAppliedToEveryGraphAndOnStart() throws {
        let (engine, fake, _) = makeEngine()
        engine.setDuckingExempt(true)
        XCTAssertTrue(fake.calls.isEmpty)

        engine.apply(plan(["speakers": [spec("A", 1)], "airpods": [spec("B", 2)]]))
        let aggS = try XCTUnwrap(engine.runningAggregates[key("speakers", "A")])
        let aggA = try XCTUnwrap(engine.runningAggregates[key("airpods", "B")])
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
        let agg = try XCTUnwrap(engine.runningAggregates[key("speakers", "A")])

        clock.advance(.seconds(1.5))
        engine.checkIO()
        XCTAssertEqual(engine.runningAggregates[key("speakers", "A")], agg, "not yet 2 s")

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
        XCTAssertNotNil(engine.runningAggregates[key("bt", "A")], "within 2 x 2 s")
        XCTAssertFalse(log.events.contains(.permissionPending))

        clock.advance(.seconds(0.2))
        engine.checkIO()
        XCTAssertEqual(log.events.last, .permissionPending)
        XCTAssertNil(engine.runningAggregates[key("bt", "A")])
    }

    /// `.granted` comes from seeing IO, not from starting a device; confirmed once per run.
    func testCallbacksConfirmIOOnce() throws {
        let (engine, fake, log) = makeEngine(ioTimeout: .seconds(2))
        let clock = watched(engine)
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        let agg = try XCTUnwrap(engine.runningAggregates[key("speakers", "A")])
        engine.checkIO()
        XCTAssertFalse(log.events.contains(.ioConfirmed(uid: "speakers")), "no callbacks yet")

        for _ in 0..<5 { // IO keeps running: never stalled
            fake.invokeIO(aggregate: agg)
            clock.advance(.seconds(1))
            engine.checkIO()
        }

        XCTAssertEqual(log.events.filter { $0 == .ioConfirmed(uid: "speakers") }.count, 1)
        XCTAssertFalse(engine.permissionPending)
        XCTAssertEqual(engine.runningAggregates[key("speakers", "A")], agg)

        // Once confirmed, a later graph that never runs is a stall, not a permission problem.
        engine.apply(plan(["speakers": [spec("A", 1)], "airpods": [spec("B", 2)]]))
        clock.advance(.seconds(2.1))
        fake.invokeIO(aggregate: agg)
        engine.checkIO()
        XCTAssertEqual(log.events.last, .ioStalled(uid: "airpods", appID: "B"))
        XCTAssertFalse(engine.permissionPending)
        engine.stopAll()
    }

    /// IO that stops advancing after it ran: torn down, reported, retried after a 5 s back-off.
    /// The back-off is per app: another app's graph on the same device keeps running and B
    /// may still start there.
    func testFrozenAfterStartReportsStallAndBacksOffThatAppOnly() throws {
        let (engine, fake, log) = makeEngine(ioTimeout: .seconds(2))
        let clock = watched(engine)
        engine.apply(plan(["speakers": [spec("A", 1), spec("C", 3)]]))
        let agg = try XCTUnwrap(engine.runningAggregates[key("speakers", "A")])
        let aggC = try XCTUnwrap(engine.runningAggregates[key("speakers", "C")])
        fake.invokeIO(aggregate: agg)
        engine.checkIO()

        clock.advance(.seconds(2.1))
        fake.invokeIO(aggregate: aggC) // C keeps running
        engine.checkIO()

        XCTAssertEqual(log.events.last, .ioStalled(uid: "speakers", appID: "A"))
        XCTAssertFalse(engine.permissionPending)
        XCTAssertNil(engine.runningAggregates[key("speakers", "A")], "torn down: the app plays directly")
        XCTAssertEqual(engine.runningAggregates[key("speakers", "C")], aggC, "C unaffected")
        XCTAssertEqual(fake.activeIOCount, 1)
        XCTAssertEqual(engine.stalledGraphs, [key("speakers", "A")])

        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2), spec("C", 3)]]))
        XCTAssertNil(engine.runningAggregates[key("speakers", "A")], "backing off")
        XCTAssertNotNil(engine.runningAggregates[key("speakers", "B")], "B is not backing off")
        clock.advance(.seconds(5))
        XCTAssertEqual(engine.stalledGraphs, [])
        engine.apply(plan(["speakers": [spec("A", 1), spec("B", 2), spec("C", 3)]]))
        XCTAssertNotNil(engine.runningAggregates[key("speakers", "A")], "retried after 5 s")
        engine.stopAll()
    }

    /// A pinned app (System Sounds) on a dead device would restart forever: each stall without IO
    /// doubles its back-off (5, 10, 20, 40, 60, 60 s); IO seen on it resets it to 5 s.
    func testPinnedStallBackoffGrowsAndResetsAfterIO() throws {
        let (engine, fake, _) = makeEngine(ioTimeout: .seconds(2))
        let clock = watched(engine)
        let pinned = key("speakers", SystemSounds.appID)
        let p = plan(["speakers": [spec(SystemSounds.appID, 1)]])
        engine.apply(p)
        fake.invokeIO(aggregate: try XCTUnwrap(engine.runningAggregates[pinned]))
        engine.checkIO()

        for expected in [5.0, 10, 20, 40, 60, 60] {
            clock.advance(.seconds(2.1))
            engine.checkIO()
            XCTAssertNil(engine.runningAggregates[pinned], "stalled")
            clock.advance(.seconds(expected - 0.5)) // binary-exact margins
            engine.apply(p)
            XCTAssertNil(engine.runningAggregates[pinned], "still backing off before \(expected) s")
            clock.advance(.seconds(0.5))
            engine.apply(p)
            XCTAssertNotNil(engine.runningAggregates[pinned], "retried after \(expected) s")
        }

        fake.invokeIO(aggregate: try XCTUnwrap(engine.runningAggregates[pinned]))
        engine.checkIO()
        clock.advance(.seconds(2.1))
        engine.checkIO()
        clock.advance(.seconds(5))
        engine.apply(p)
        XCTAssertNotNil(engine.runningAggregates[pinned], "back to 5 s after IO was seen")
        engine.stopAll()
    }
}
