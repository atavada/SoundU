import CoreAudio
import Foundation
import XCTest
@testable import SoundUCore

final class RoutingPlannerTests: XCTestCase {
    // MARK: - Fixtures

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let speakers = OutputDevice(id: 10, uid: "speakers", name: "MacBook Speakers",
                                        sampleRate: 48_000, outputChannels: 2, transport: 0)
    private let airPods = OutputDevice(id: 20, uid: "airpods", name: "AirPods",
                                       sampleRate: 48_000, outputChannels: 2, transport: 0)
    private let selfID = "com.example.SoundU"

    private func proc(_ objectID: AudioObjectID, output: Bool = true) -> ProcessSnapshot {
        ProcessSnapshot(objectID: objectID, pid: pid_t(objectID) + 1000, bundleID: nil,
                        executablePath: "/bin/p\(objectID)", parentPID: 1, responsiblePID: pid_t(objectID) + 1000,
                        isRunningOutput: output, isRunningInput: false)
    }

    private func app(_ id: String, _ procs: [ProcessSnapshot]) -> AudioApp {
        AudioApp(id: id, name: id, processes: procs)
    }

    private func input(_ apps: [AudioApp], shared: [AudioObjectID: Set<String>] = [:],
                       settings: SettingsSnapshot = SettingsSnapshot(),
                       devices: [OutputDevice]? = nil, defaultUID: String = "speakers",
                       calls: Set<String> = [], lastPlayed: [String: Date] = [:],
                       failed: Set<String> = []) -> PlannerInput {
        PlannerInput(grouping: Grouping(apps: apps, sharedOwners: shared), settings: settings,
                     devices: devices ?? [speakers, airPods], defaultDeviceUID: defaultUID,
                     activeCallApps: calls, lastPlayed: lastPlayed, now: now,
                     selfBundleID: selfID, failedApps: failed)
    }

    private func settings(_ uids: [String: String]) -> SettingsSnapshot {
        SettingsSnapshot(apps: uids.mapValues { AppSetting(volume: 1, muted: false, outputDeviceUID: $0) })
    }

    // MARK: - Tests

    func testEveryPlayingAppIsRouted() {
        let result = plan(input([
            app("com.spotify.client", [proc(5)]),
            app("com.apple.Safari", [proc(9), proc(3)]),
            app("com.apple.Music", [proc(7, output: false)]),
        ], settings: settings(["com.spotify.client": "airpods"])))

        XCTAssertEqual(result, RoutingPlan(byDevice: [
            "speakers": [TapSpec(appID: "com.apple.Safari", processObjectIDs: [3, 9])],
            "airpods": [TapSpec(appID: "com.spotify.client", processObjectIDs: [5])],
        ], excluded: [:]))
    }

    func testSoundUExcluded() {
        let result = plan(input([app(selfID, [proc(1)]), app("com.apple.Music", [proc(2)])]))
        XCTAssertEqual(result.byDevice, ["speakers": [TapSpec(appID: "com.apple.Music", processObjectIDs: [2])]])
        XCTAssertEqual(result.excluded, [selfID: .soundU])
    }

    func testCallAppUntappedDuringCall() {
        let apps = [app("net.whatsapp.WhatsApp", [proc(1)]), app("com.apple.Music", [proc(2)])]
        let during = plan(input(apps, calls: ["net.whatsapp.WhatsApp"]))
        XCTAssertEqual(during.byDevice, ["speakers": [TapSpec(appID: "com.apple.Music", processObjectIDs: [2])]])
        XCTAssertEqual(during.excluded, ["net.whatsapp.WhatsApp": .callInProgress])

        let after = plan(input(apps))
        XCTAssertEqual(after.byDevice["speakers"]?.map(\.appID), ["com.apple.Music", "net.whatsapp.WhatsApp"])
        XCTAssertEqual(after.excluded, [:])
    }

    func testSharedProcessDroppedDuringCall() {
        // Process 4 (avconferenced) is held by FaceTime but shared with Phone; Phone is in a call.
        let shared: [AudioObjectID: Set<String>] = [4: ["com.apple.FaceTime", "com.apple.mobilephone"],
                                                    6: ["com.google.Chrome", "com.apple.mobilephone"]]
        let apps = [
            app("com.apple.FaceTime", [proc(4)]),
            app("com.google.Chrome", [proc(5), proc(6)]),
            app("com.apple.mobilephone", [proc(8)]),
        ]
        let result = plan(input(apps, shared: shared, calls: ["com.apple.mobilephone"]))

        XCTAssertEqual(result.byDevice, ["speakers": [TapSpec(appID: "com.google.Chrome", processObjectIDs: [5])]])
        XCTAssertEqual(result.excluded, ["com.apple.FaceTime": .sharedWithCall,
                                         "com.apple.mobilephone": .callInProgress])
    }

    func testLingersFiveSecondsAfterStop() {
        let apps = [app("com.apple.Music", [proc(2, output: false)])]
        let lingering = plan(input(apps, lastPlayed: ["com.apple.Music": now.addingTimeInterval(-4.9)]))
        XCTAssertEqual(lingering.byDevice, ["speakers": [TapSpec(appID: "com.apple.Music", processObjectIDs: [2])]])

        let released = plan(input(apps, lastPlayed: ["com.apple.Music": now.addingTimeInterval(-5.1)]))
        XCTAssertEqual(released, RoutingPlan(byDevice: [:], excluded: [:]))
    }

    func testMissingDeviceFallsBackToDefault() {
        let apps = [app("com.spotify.client", [proc(5)])]
        let routed = settings(["com.spotify.client": "airpods"])
        let connected = plan(input(apps, settings: routed))
        XCTAssertEqual(connected.byDevice.keys.sorted(), ["airpods"])

        let disconnected = plan(input(apps, settings: routed, devices: [speakers]))
        XCTAssertEqual(disconnected.byDevice, ["speakers": [TapSpec(appID: "com.spotify.client", processObjectIDs: [5])]])
    }

    func testDefaultChangeMovesDefaultApps() {
        let apps = [app("com.apple.Music", [proc(2)]), app("com.spotify.client", [proc(5)])]
        let pinned = settings(["com.spotify.client": "speakers"])
        let before = plan(input(apps, settings: pinned, defaultUID: "speakers"))
        XCTAssertEqual(before.byDevice["speakers"]?.map(\.appID), ["com.apple.Music", "com.spotify.client"])

        let after = plan(input(apps, settings: pinned, defaultUID: "airpods"))
        XCTAssertEqual(after.byDevice, [
            "airpods": [TapSpec(appID: "com.apple.Music", processObjectIDs: [2])],
            "speakers": [TapSpec(appID: "com.spotify.client", processObjectIDs: [5])],
        ])
    }

    func testChromeHelperChurnChangesOnlyChromeSpec() {
        let others = [app("com.apple.Music", [proc(2)]), app("com.spotify.client", [proc(5)])]
        let before = plan(input(others + [app("com.google.Chrome", [proc(10), proc(12)])]))
        let after = plan(input(others + [app("com.google.Chrome", [proc(10), proc(11, output: false), proc(12)])]))

        let beforeSpecs = before.byDevice["speakers"] ?? []
        let afterSpecs = after.byDevice["speakers"] ?? []
        XCTAssertEqual(beforeSpecs.map(\.appID), afterSpecs.map(\.appID))
        XCTAssertEqual(Set(afterSpecs).subtracting(beforeSpecs).map(\.appID), ["com.google.Chrome"])
        XCTAssertEqual(afterSpecs.first { $0.appID == "com.google.Chrome" }?.processObjectIDs, [10, 11, 12])
        XCTAssertEqual(before.excluded, after.excluded)
    }

    func testFailedAppNotRouted() {
        let result = plan(input([app("com.apple.Music", [proc(2)]), app("com.spotify.client", [proc(5)])],
                                failed: ["com.spotify.client"]))
        XCTAssertEqual(result.byDevice, ["speakers": [TapSpec(appID: "com.apple.Music", processObjectIDs: [2])]])
        XCTAssertEqual(result.excluded, ["com.spotify.client": .tapFailed])
    }
}
