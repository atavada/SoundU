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

    private func makeController(settings: SettingsSnapshot = SettingsSnapshot(), playing: Bool = true)
        throws -> (SoundUController, FakeAudioSystem, SettingsStore) {
        let fake = FakeAudioSystem()
        fake.devices = [speakers, airPods]
        fake.defaultUID = "speakers"
        fake.processList = [process(1, owner: spotify, playing: playing)]
        let store = SettingsStore(url: storeURL)
        try store.save(settings)
        let apps = [spotify]
        let controller = SoundUController(system: fake, store: store, runningApps: { apps },
                                          selfBundleID: "com.example.SoundU", permissionTimeout: .seconds(60))
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
}
