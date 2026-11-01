import CoreAudio
import XCTest
@testable import SoundUCore

/// Runs against the real HAL. Opt in with `SOUNDU_HW_TESTS=1`.
/// Never creates process taps (the test runner has no Audio Capture permission).
final class CoreAudioSystemHardwareTests: XCTestCase {
    private var system: CoreAudioSystem!
    private var aggregates: [AudioObjectID] = []

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOUNDU_HW_TESTS"] == "1",
                          "set SOUNDU_HW_TESTS=1 to run hardware tests")
        system = CoreAudioSystem()
    }

    override func tearDown() {
        for agg in aggregates { system.destroyAggregate(agg) }
        aggregates = []
    }

    func testListsDefaultOutputDevice() throws {
        let uid = try XCTUnwrap(system.defaultOutputDeviceUID())
        XCTAssertFalse(uid.isEmpty)
        XCTAssertTrue(system.outputDevices().contains { $0.uid == uid })
    }

    func testNoDuckRoundTrip() throws {
        let uid = try XCTUnwrap(system.defaultOutputDeviceUID())
        try XCTSkipUnless(system.isNoDuckSupported(), "'nodk' not settable on default output")
        let agg = try system.createAggregate(deviceUID: uid, tapUIDs: [])
        aggregates.append(agg)

        let subs = HAL.objectIDs(agg, kAudioAggregateDevicePropertyActiveSubDeviceList)
        XCTAssertFalse(subs.isEmpty)

        XCTAssertTrue(system.setNoDuck(subDevicesOf: agg, true))
        for sub in subs {
            XCTAssertEqual(HAL.uint32(sub, HAL.noDuckSelector, kAudioObjectPropertyScopeOutput), 1)
        }
        XCTAssertTrue(system.setNoDuck(subDevicesOf: agg, false))
        for sub in subs {
            XCTAssertEqual(HAL.uint32(sub, HAL.noDuckSelector, kAudioObjectPropertyScopeOutput), 0)
        }
    }

    /// Starting IO on a zero-tap aggregate (writing silence) makes this process an output client,
    /// which `observe` reports as `.processes` (via the per-process IsRunning listener).
    func testIOProcRunsAndProcessIsObserved() throws {
        let uid = try XCTUnwrap(system.defaultOutputDeviceUID())
        let agg = try system.createAggregate(deviceUID: uid, tapUIDs: [])
        aggregates.append(agg)
        XCTAssertGreaterThan(system.addedLatencyMs(aggregate: agg), 0)

        let changed = expectation(description: "processes change observed")
        changed.assertForOverFulfill = false
        let token = system.observe { if $0 == .processes { changed.fulfill() } }

        let callbacks = expectation(description: "IOProc called")
        callbacks.assertForOverFulfill = false
        let proc = try system.startIO(aggregate: agg, inputStreamUsage: nil) { _, _, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            callbacks.fulfill()
        }
        defer { system.stopIO(aggregate: agg, proc: proc) }
        wait(for: [callbacks, changed], timeout: 3)

        let me = system.processes().first { $0.pid == getpid() }
        XCTAssertEqual(me?.isRunningOutput, true)
        XCTAssertEqual(me?.parentPID, getppid())
        XCTAssertFalse(me?.executablePath.isEmpty ?? true)
        withExtendedLifetime(token) {}
    }

    /// A new process appearing (a near-silent system sound) is reported as `.processes`
    /// (via the process-list listener).
    func testObserveReportsNewProcess() throws {
        let changed = expectation(description: "processes change observed")
        changed.assertForOverFulfill = false
        let token = system.observe { if $0 == .processes { changed.fulfill() } }

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.01", "/System/Library/Sounds/Tink.aiff"]
        try player.run()
        wait(for: [changed], timeout: 3)
        player.waitUntilExit()
        withExtendedLifetime(token) {}
    }

    /// The IOProcStreamUsage encoding round-trips on a real aggregate over a built-in device with
    /// input streams. The IOProc is created but never started, so no microphone is opened.
    /// Slow (~150 s on macOS 26.5): on such an aggregate coreaudiod runs a microphone TCC preflight
    /// for the test runner and IOProc create/destroy each stall ~60 s, the usage set ~30 s.
    func testInputStreamUsageRoundTrips() throws {
        let input = HAL.objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
            .first {
                HAL.uint32($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
                    && !HAL.objectIDs($0, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).isEmpty
            }
        let uid = try XCTUnwrap(input.flatMap { HAL.string($0, kAudioDevicePropertyDeviceUID) }, "no input device")
        let agg = try system.createAggregate(deviceUID: uid, tapUIDs: [])
        aggregates.append(agg)
        let streams = system.inputStreamCount(aggregate: agg)
        try XCTSkipUnless(streams > 0, "aggregate has no input streams")

        var proc: AudioDeviceIOProcID?
        XCTAssertEqual(AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, _, _, _, _ in }, noErr)
        let id = try XCTUnwrap(proc)
        defer { AudioDeviceDestroyIOProcID(agg, id) }
        let wanted = (0..<streams).map { $0 % 2 == 1 }
        system.setInputStreamUsage(aggregate: agg, proc: id, wanted)

        // Read back: the getter needs mIOProc filled in.
        typealias Usage = AudioHardwareIOProcStreamUsage
        let flags = MemoryLayout<Usage>.offset(of: \Usage.mStreamIsOn)!
        var size = UInt32(max(MemoryLayout<Usage>.size, flags + streams * 4))
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<Usage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        raw.storeBytes(of: unsafeBitCast(id, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(streams), toByteOffset: MemoryLayout<Usage>.offset(of: \Usage.mNumberStreams)!,
                       as: UInt32.self)
        var addr = HAL.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        XCTAssertEqual(AudioObjectGetPropertyData(agg, &addr, 0, nil, &size, raw), noErr)
        let got = (0..<streams).map { raw.load(fromByteOffset: flags + $0 * 4, as: UInt32.self) != 0 }
        XCTAssertEqual(got, wanted)
    }

    func testAudioDeviceDuckSymbolResolves() {
        XCTAssertNotNil(HAL.audioDeviceDuck())
    }
}
