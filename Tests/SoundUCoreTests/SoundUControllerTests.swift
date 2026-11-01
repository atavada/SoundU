import CoreAudio
import Foundation
import XCTest
@testable import SoundUCore

@MainActor
final class SoundUControllerTests: XCTestCase {
    // MARK: - Fixtures

    private let speakers = OutputDevice(id: 10, uid: "speakers", name: "MacBook Speakers",
                                        sampleRate: 48_000, outputChannels: 2, transport: 0)
    private let airPods = OutputDevice(id: 20, uid: "airpods", name: "AirPods",
                                       sampleRate: 48_000, outputChannels: 2, transport: 0)
    private let spotifyID = "com.spotify.client"
    private let spotify = RunningApp(pid: 100, bundleID: "com.spotify.client", name: "Spotify")

    private var storeURL: URL!

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundUControllerTests-\(UUID().uuidString)/settings.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    private func process(_ objectID: AudioObjectID, owner: RunningApp, playing: Bool) -> ProcessSnapshot {
        ProcessSnapshot(objectID: objectID, pid: owner.pid, bundleID: owner.bundleID,
                        executablePath: "/Applications/\(owner.name).app/Contents/MacOS/\(owner.name)",
                        parentPID: 1, responsiblePID: owner.pid, isRunningOutput: playing, isRunningInput: false)
    }

    private func makeController(settings: SettingsSnapshot = SettingsSnapshot(), playing: Bool = true,
                                ioTimeout: Duration = .seconds(60))
        throws -> (SoundUController, FakeAudioSystem, SettingsStore) {
        let fake = FakeAudioSystem()
        fake.devices = [speakers, airPods]
        fake.defaultUID = "speakers"
        fake.processList = [process(1, owner: spotify, playing: playing)]
        let store = SettingsStore(url: storeURL)
        try store.save(settings)
        let apps = [spotify]
        let controller = SoundUController(system: fake, store: store, runningApps: { apps },
                                          selfBundleID: "com.example.SoundU", ioTimeout: ioTimeout)
        return (controller, fake, store)
    }

    /// Polls `condition` every 20 ms until it holds or `timeout` passes.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func strip(_ controller: SoundUController, _ id: String) -> AppStrip? {
        controller.apps.first { $0.id == id }
    }

    /// Runs `cycles` IO callbacks on `agg` with one constant stereo input buffer and returns the
    /// left sample of the last output frame.
    private func render(_ fake: FakeAudioSystem, _ agg: AudioObjectID, input value: Float,
                        frames: Int = 64, cycles: Int) -> Float {
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        let inData = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        let outData = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer {
            inData.deallocate(); outData.deallocate()
            free(input.unsafeMutablePointer); free(output.unsafeMutablePointer)
        }
        inData.initialize(repeating: value, count: frames * 2)
        outData.initialize(repeating: 0, count: frames * 2)
        let size = UInt32(frames * 2 * 4)
        input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: size, mData: inData)
        output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: size, mData: outData)
        for _ in 0..<cycles {
            fake.invokeIO(aggregate: agg, input: input.unsafePointer, output: output.unsafeMutablePointer)
        }
        return outData[(frames - 1) * 2]
    }

    // MARK: - Tests

    func testVolumeChangePersistsAndReachesEngine() async throws {
        let (controller, fake, store) = try makeController()
        controller.start()
        defer { controller.shutdown() }
        let routed = await waitUntil(1) { self.strip(controller, self.spotifyID)?.state == .routed }
        XCTAssertTrue(routed, "strips: \(controller.apps)")
        let agg = try XCTUnwrap(controller.engine.runningAggregates["speakers"])

        controller.setVolume(spotifyID, 0.3)

        XCTAssertEqual(strip(controller, spotifyID)?.volume, 0.3)
        // 20 × 64 frames is past the 480-frame ramp at 48 kHz.
        XCTAssertEqual(render(fake, agg, input: 0.5, cycles: 20), 0.15, accuracy: 0.001)
        XCTAssertNotEqual(store.load().setting(for: spotifyID).volume, 0.3, "saved before the 0.5 s debounce")
        let saved = await waitUntil(1.5) { store.load().setting(for: self.spotifyID).volume == 0.3 }
        XCTAssertTrue(saved)
    }

    func testDeviceUnplugMovesAppsToDefaultWithinOneSecond() async throws {
        var settings = SettingsSnapshot()
        settings.apps[spotifyID] = AppSetting(volume: 1, muted: false, outputDeviceUID: "airpods")
        let (controller, fake, _) = try makeController(settings: settings)
        controller.start()
        defer { controller.shutdown() }
        let onAirPods = await waitUntil(1) { controller.engine.runningAggregates["airpods"] != nil }
        XCTAssertTrue(onAirPods)

        fake.devices = [speakers]
        fake.send(.devices)

        let moved = await waitUntil(1) {
            controller.engine.runningAggregates.keys.sorted() == ["speakers"]
        }
        XCTAssertTrue(moved, "aggregates: \(controller.engine.runningAggregates)")
        XCTAssertEqual(controller.devices, [speakers])
        XCTAssertEqual(strip(controller, spotifyID)?.state, .routed)
        XCTAssertEqual(strip(controller, spotifyID)?.outputDeviceUID, "airpods", "saved preference is kept")
    }

    func testRecentlySilentAppShownLingering() async throws {
        let (controller, fake, _) = try makeController()
        controller.start()
        defer { controller.shutdown() }
        let routed = await waitUntil(1) { self.strip(controller, self.spotifyID)?.state == .routed }
        XCTAssertTrue(routed)

        fake.processList = [process(1, owner: spotify, playing: false)]
        fake.send(.processes)

        let lingering = await waitUntil(1) { self.strip(controller, self.spotifyID)?.state == .lingering }
        XCTAssertTrue(lingering, "strips: \(controller.apps)")
        XCTAssertNotNil(controller.engine.runningAggregates["speakers"], "still tapped while lingering")
    }

    func testMeterLevelsPublishedPerApp() async throws {
        let (controller, fake, _) = try makeController()
        controller.start()
        defer { controller.shutdown() }
        let routed = await waitUntil(1) { self.strip(controller, self.spotifyID)?.state == .routed }
        XCTAssertTrue(routed)
        let agg = try XCTUnwrap(controller.engine.runningAggregates["speakers"])

        // Keep audio flowing while polling: each meter tick consumes the peaks.
        let metered = await waitUntil(1) {
            _ = self.render(fake, agg, input: 0.5, cycles: 2)
            return (controller.levels[self.spotifyID] ?? 0) > 0
        }
        XCTAssertTrue(metered, "levels: \(controller.levels)")
    }

    func testPrepareForTerminationSavesNowWithoutTeardown() async throws {
        let (controller, fake, store) = try makeController()
        controller.start()
        let routed = await waitUntil(1) { self.strip(controller, self.spotifyID)?.state == .routed }
        XCTAssertTrue(routed)
        controller.setVolume(spotifyID, 0.4)
        let callsBefore = fake.calls

        controller.prepareForTermination()

        XCTAssertEqual(store.load().setting(for: spotifyID).volume, 0.4, "saved without waiting for the debounce")
        XCTAssertEqual(fake.calls, callsBefore, "no HAL calls: IO, aggregates and taps vanish with the process")
        XCTAssertEqual(fake.activeIOCount, 1, "IO left running")
        try? await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(fake.calls, callsBefore, "loops stopped: no re-plan after termination prep")
    }

    /// Review Focus 1 at the controller: no IO callbacks → `.pending`, nothing left tapped.
    func testPermissionPendingWhenEngineReportsIt() async throws {
        let (controller, fake, _) = try makeController(ioTimeout: .milliseconds(50))
        controller.start()
        defer { controller.shutdown() }

        // The watchdog runs on the 1 s re-plan.
        let pending = await waitUntil(2) { controller.permission == .pending }

        XCTAssertTrue(pending, "permission: \(controller.permission)")
        XCTAssertTrue(controller.engine.runningAggregates.isEmpty, "no apps routed")
        XCTAssertEqual(fake.activeIOCount, 0)
        XCTAssertEqual(strip(controller, spotifyID)?.state, .notRouted(.permissionPending))
    }

    func testGrantedOnlyOnceIOIsConfirmed() async throws {
        let (controller, fake, _) = try makeController()
        controller.start()
        defer { controller.shutdown() }
        let routed = await waitUntil(1) { self.strip(controller, self.spotifyID)?.state == .routed }
        XCTAssertTrue(routed)
        let agg = try XCTUnwrap(controller.engine.runningAggregates["speakers"])

        try? await Task.sleep(for: .milliseconds(1200)) // a timed re-plan, no IO yet
        XCTAssertEqual(controller.permission, .unknown, "starting a device is not proof of permission")

        fake.invokeIO(aggregate: agg)
        let granted = await waitUntil(2) { controller.permission == .granted }
        XCTAssertTrue(granted, "permission: \(controller.permission)")
    }

    /// IO that stops after it ran: the graph is torn down (the app plays directly) and the strip
    /// shows an error until the 5 s back-off retry.
    func testStalledIOShowsStripErrorAndUntaps() async throws {
        let (controller, fake, _) = try makeController(ioTimeout: .milliseconds(50))
        controller.start()
        defer { controller.shutdown() }
        let started = await waitUntil(1) { controller.engine.runningAggregates["speakers"] != nil }
        XCTAssertTrue(started)
        let agg = try XCTUnwrap(controller.engine.runningAggregates["speakers"])
        fake.invokeIO(aggregate: agg)

        let stalled = await waitUntil(3.5) {
            if case .error = self.strip(controller, self.spotifyID)?.state { true } else { false }
        }

        XCTAssertTrue(stalled, "strips: \(controller.apps)")
        XCTAssertEqual(controller.permission, .granted)
        XCTAssertTrue(controller.engine.runningAggregates.isEmpty)
        XCTAssertEqual(fake.activeIOCount, 0)
    }

    func testCeilingChangeClampsExistingVolumes() async throws {
        var settings = SettingsSnapshot()
        settings.apps[spotifyID] = AppSetting(volume: 1.8, muted: false, outputDeviceUID: nil)
        let (controller, fake, store) = try makeController(settings: settings)
        controller.start()
        defer { controller.shutdown() }
        let routed = await waitUntil(1) { self.strip(controller, self.spotifyID)?.state == .routed }
        XCTAssertTrue(routed, "strips: \(controller.apps)")
        let agg = try XCTUnwrap(controller.engine.runningAggregates["speakers"])
        XCTAssertEqual(render(fake, agg, input: 0.5, cycles: 40), 0.9, accuracy: 0.001)

        controller.setBoostCeiling(1.2)

        XCTAssertEqual(controller.global.boostCeiling, 1.2)
        XCTAssertEqual(controller.boostCeiling, 1.2)
        XCTAssertEqual(strip(controller, spotifyID)?.volume, 1.2)
        XCTAssertEqual(render(fake, agg, input: 0.5, cycles: 40), 0.6, accuracy: 0.001)
        let saved = await waitUntil(1.5) {
            let s = store.load()
            return s.global.boostCeiling == 1.2 && s.apps[self.spotifyID]?.volume == 1.2
        }
        XCTAssertTrue(saved)

        controller.setBoostCeiling(5)
        XCTAssertEqual(controller.global.boostCeiling, 2, "ceiling clamped to 1.0...2.0")
        controller.setBoostCeiling(0.5)
        XCTAssertEqual(controller.global.boostCeiling, 1)
    }

    func testCallAppListEditPersists() async throws {
        let (controller, _, store) = try makeController()
        let defaults = GlobalSettings().callApps

        controller.setCallApps(defaults + ["us.zoom.xos"])
        controller.setCallGuardEnabled(false)

        XCTAssertEqual(controller.global.callApps, defaults + ["us.zoom.xos"])
        XCTAssertFalse(controller.global.callGuardEnabled)
        let saved = await waitUntil(1.5) {
            let g = store.load().global
            return g.callApps == defaults + ["us.zoom.xos"] && !g.callGuardEnabled
        }
        XCTAssertTrue(saved)

        controller.resetCallApps()
        controller.prepareForTermination()

        XCTAssertEqual(controller.global.callApps, defaults)
        XCTAssertEqual(store.load().global.callApps, defaults)
    }

    // MARK: - Call Guard

    private let whatsAppID = "net.whatsapp.WhatsApp"

    /// A WhatsApp process (not a running app here, so it groups under its own bundle ID).
    private func whatsAppProcess(inCall: Bool) -> ProcessSnapshot {
        ProcessSnapshot(objectID: 2, pid: 300, bundleID: whatsAppID,
                        executablePath: "/Applications/WhatsApp.app/Contents/MacOS/WhatsApp",
                        parentPID: 1, responsiblePID: 300, isRunningOutput: inCall, isRunningInput: inCall)
    }

    private func noDuckCalls(_ fake: FakeAudioSystem) -> [FakeAudioSystem.Call] {
        fake.calls.filter { if case .setNoDuck = $0 { true } else { false } }
    }

    func testCallLocksCallAppAndKeepsOutputExempt() async throws {
        let (controller, fake, _) = try makeController()
        controller.start()
        defer { controller.shutdown() }
        let on = await waitUntil(1) {
            controller.callGuard == .on && controller.engine.runningAggregates["speakers"] != nil
        }
        XCTAssertTrue(on, "status: \(controller.callGuard)")
        let agg = try XCTUnwrap(controller.engine.runningAggregates["speakers"])
        XCTAssertEqual(noDuckCalls(fake), [.setNoDuck(agg, true)], "exempt whenever SoundU plays")

        fake.processList = [process(1, owner: spotify, playing: true), whatsAppProcess(inCall: true)]
        fake.send(.processes)

        let protecting = await waitUntil(1) { controller.callGuard == .protecting(appName: "WhatsApp") }
        XCTAssertTrue(protecting, "status: \(controller.callGuard)")
        XCTAssertEqual(strip(controller, whatsAppID)?.state, .locked(callApp: whatsAppID))
        XCTAssertFalse(fake.calls.contains { call in
            if case .createTap(_, let name) = call { name.contains(whatsAppID) } else { false }
        }, "the call app is never tapped")
        try? await Task.sleep(for: .milliseconds(1100)) // at least one timed re-plan
        XCTAssertEqual(noDuckCalls(fake), [.setNoDuck(agg, true)], "exemption is set only when it changes")

        fake.processList = [process(1, owner: spotify, playing: true), whatsAppProcess(inCall: false)]
        fake.send(.processes)

        let ended = await waitUntil(1) { controller.callGuard == .on }
        XCTAssertTrue(ended, "status: \(controller.callGuard)")
        // It played seconds ago, so it lingers (routed) like any app until the 5 s linger ends.
        XCTAssertEqual(strip(controller, whatsAppID)?.state, .lingering, "unlocked after the call")
    }

    func testVoiceOverAndDisablingDropTheExemption() async throws {
        let (controller, fake, _) = try makeController()
        controller.start()
        defer { controller.shutdown() }
        let started = await waitUntil(1) { controller.engine.runningAggregates["speakers"] != nil }
        XCTAssertTrue(started)
        let agg = try XCTUnwrap(controller.engine.runningAggregates["speakers"])

        fake.runningBundleIDs = ["com.apple.VoiceOver"]
        let dropped = await waitUntil(2.5) { self.noDuckCalls(fake).last == .setNoDuck(agg, false) }
        XCTAssertTrue(dropped, "calls: \(noDuckCalls(fake))")
        XCTAssertEqual(controller.callGuard, .on, "VoiceOver keeps Call Guard on; only the exemption is skipped")

        fake.runningBundleIDs = []
        let restored = await waitUntil(2.5) { self.noDuckCalls(fake).last == .setNoDuck(agg, true) }
        XCTAssertTrue(restored, "calls: \(noDuckCalls(fake))")

        controller.setCallGuardEnabled(false)
        XCTAssertEqual(controller.callGuard, .off, "status follows the toggle at once")
        XCTAssertEqual(noDuckCalls(fake).last, .setNoDuck(agg, false))
    }

    func testUnavailableWithoutAnyExemptionMechanism() async throws {
        let (controller, fake, _) = try makeController()
        fake.noDuckSupported = false
        controller.duckFallbackAvailable = { false }
        controller.start()
        defer { controller.shutdown() }

        let unavailable = await waitUntil(1) { controller.callGuard == .unavailable }
        XCTAssertTrue(unavailable, "status: \(controller.callGuard)")
        XCTAssertTrue(noDuckCalls(fake).isEmpty)
    }

    func testFirstRunAndLaunchAtLoginFlagsPersist() throws {
        let (controller, _, store) = try makeController()
        XCTAssertFalse(controller.global.firstRunDone)

        controller.markFirstRunDone()
        controller.setLaunchAtLogin(true)
        controller.prepareForTermination()

        XCTAssertTrue(store.load().global.firstRunDone)
        XCTAssertTrue(store.load().global.launchAtLogin)
    }
}
