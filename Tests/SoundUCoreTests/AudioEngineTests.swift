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

    private func makeEngine(permissionTimeout: Duration = .seconds(60))
        -> (AudioEngine, FakeAudioSystem, EventLog) {
        let fake = FakeAudioSystem()
        fake.devices = [speakers, airPods]
        fake.defaultUID = "speakers"
        let engine = AudioEngine(system: fake, permissionTimeout: permissionTimeout)
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
        XCTAssertEqual(render(fake, agg, inputs: [0.1]), 0, accuracy: 1e-6)
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

    /// Review Focus 1: no IO callbacks (permission not granted) → report, untap, keep apps playing.
    func testNoCallbacksReportsPermissionPendingAndUntaps() async throws {
        let (engine, fake, log) = makeEngine(permissionTimeout: .milliseconds(50))
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        let agg = try XCTUnwrap(engine.runningAggregates["speakers"])

        try await Task.sleep(for: .milliseconds(300))

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

    func testCallbacksWithinTimeoutConfirmPermission() async throws {
        let (engine, fake, log) = makeEngine(permissionTimeout: .milliseconds(50))
        engine.apply(plan(["speakers": [spec("A", 1)]]))
        let agg = try XCTUnwrap(engine.runningAggregates["speakers"])
        fake.invokeIO(aggregate: agg)

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(log.events.contains(.permissionPending))
        XCTAssertFalse(engine.permissionPending)
        XCTAssertEqual(engine.runningAggregates["speakers"], agg)

        // Once confirmed, later graphs are not checked again.
        engine.apply(plan(["speakers": [spec("A", 1)], "airpods": [spec("B", 2)]]))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(engine.runningAggregates["airpods"])
        engine.stopAll()
    }
}
