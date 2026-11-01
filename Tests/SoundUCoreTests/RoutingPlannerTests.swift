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

    // MARK: - System processes

    private func daemon(_ objectID: AudioObjectID, _ path: String, output: Bool = true) -> ProcessSnapshot {
        ProcessSnapshot(objectID: objectID, pid: pid_t(objectID) + 1000, bundleID: nil, executablePath: path,
                        parentPID: 1, responsiblePID: pid_t(objectID) + 1000,
                        isRunningOutput: output, isRunningInput: false)
    }

    /// Bare OS daemons other than System Sounds are never routed or shown.
    func testSystemDaemonOnlyAppExcluded() {
        let result = plan(input([
            app("coreaudiod.thing", [daemon(3, "/usr/sbin/somedaemond")]),
            app("com.apple.coreaudio.thing", [daemon(4, "/System/Library/Frameworks/X.framework/thing")]),
            app("com.apple.Music", [proc(2)]),
        ]))
        XCTAssertEqual(result.byDevice, ["speakers": [TapSpec(appID: "com.apple.Music", processObjectIDs: [2])]])
        XCTAssertEqual(result.excluded, ["coreaudiod.thing": .systemProcess,
                                         "com.apple.coreaudio.thing": .systemProcess])
    }

    // MARK: - System Sounds (pinned)

    private func systemSounds(output: Bool, responsible: pid_t? = nil) -> AudioApp {
        let p = ProcessSnapshot(objectID: 3, pid: 1003, bundleID: nil, executablePath: SystemSounds.executablePath,
                                parentPID: 1, responsiblePID: responsible ?? 1003,
                                isRunningOutput: output, isRunningInput: false)
        return AudioApp(id: SystemSounds.appID, name: SystemSounds.name, processes: [p])
    }

    /// System Sounds is routed while idle with no lastPlayed, so its tap exists before a
    /// notification starts; it is never treated as a system daemon.
    func testIdleSystemSoundsIsAlwaysRouted() {
        let expected = ["speakers": [TapSpec(appID: SystemSounds.appID, processObjectIDs: [3])]]
        for responsible: pid_t in [1003, 77] {
            let idle = plan(input([systemSounds(output: false, responsible: responsible)]))
            XCTAssertEqual(idle.byDevice, expected)
            XCTAssertEqual(idle.excluded, [:])
        }
        let playing = plan(input([systemSounds(output: true)]))
        XCTAssertEqual(playing.byDevice, expected)

        // Still routed 10 s after it last played.
        let later = plan(input([systemSounds(output: false)],
                               lastPlayed: [SystemSounds.appID: now.addingTimeInterval(-10)]))
        XCTAssertEqual(later.byDevice, expected)
        XCTAssertNil(later.excluded[SystemSounds.appID])
    }

    func testSystemSoundsFollowsSavedDeviceAndKeepsCallAndFailurePrecedence() {
        let saved = plan(input([systemSounds(output: false)], settings: settings([SystemSounds.appID: "airpods"])))
        XCTAssertEqual(saved.byDevice, ["airpods": [TapSpec(appID: SystemSounds.appID, processObjectIDs: [3])]])

        let shared = plan(input([systemSounds(output: false)], shared: [3: [SystemSounds.appID, "com.apple.FaceTime"]],
                                calls: ["com.apple.FaceTime"]))
        XCTAssertEqual(shared.excluded, [SystemSounds.appID: .sharedWithCall])

        let failed = plan(input([systemSounds(output: false)], failed: [SystemSounds.appID]))
        XCTAssertEqual(failed.byDevice, [:])
        XCTAssertEqual(failed.excluded, [SystemSounds.appID: .tapFailed])
    }

    /// An app with at least one non-system process is routed whole; call services never count as
    /// system processes (an avconferenced-only FaceTime group is still FaceTime).
    func testMixedAndCallServiceGroupsStillRouted() {
        let faceTime = [proc(4), daemon(6, "/usr/libexec/avconferenced")]
        let routed = plan(input([app("com.apple.FaceTime", faceTime)]))
        XCTAssertEqual(routed.byDevice, ["speakers": [TapSpec(appID: "com.apple.FaceTime", processObjectIDs: [4, 6])]])
        XCTAssertEqual(routed.excluded, [:])

        let avconferencedOnly = plan(input([app("com.apple.FaceTime", [daemon(6, "/usr/libexec/avconferenced")])]))
        XCTAssertEqual(avconferencedOnly.byDevice.values.joined().map(\.appID), ["com.apple.FaceTime"])

        // Call rules keep precedence.
        let during = plan(input([app("com.apple.FaceTime", [daemon(6, "/usr/libexec/avconferenced")])],
                                calls: ["com.apple.FaceTime"]))
        XCTAssertEqual(during.excluded, ["com.apple.FaceTime": .callInProgress])
    }

    /// Apple's own apps live under /System/ too (/System/Applications, WebKit's XPC services):
    /// anything inside an app, extension or XPC bundle is not a system daemon.
    func testBundledSystemLocatedAppsStillRouted() {
        let result = plan(input([
            app("com.apple.Music", [daemon(2, "/System/Applications/Music.app/Contents/MacOS/Music")]),
            app("com.apple.Safari", [daemon(5, "/System/Library/Frameworks/WebKit.framework/Versions/A/"
                                           + "XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU")]),
            app("com.apple.FaceTime", [daemon(7, "/System/Applications/FaceTime.app/Contents/MacOS/FaceTime")]),
            app("com.apple.widget", [daemon(8, "/System/Applications/Weather.app/Contents/PlugIns/"
                                           + "WeatherWidget.appex/Contents/MacOS/WeatherWidget")]),
        ]))
        XCTAssertEqual(result.byDevice.values.joined().map(\.appID).sorted(),
                       ["com.apple.FaceTime", "com.apple.Music", "com.apple.Safari", "com.apple.widget"])
        XCTAssertEqual(result.excluded, [:])
    }

    /// A /usr/bin tool launched by an app (afplay from Terminal) belongs to that app, not the OS:
    /// only processes that are their own responsible process (launchd daemons) count.
    func testToolLaunchedByAppIsNotASystemDaemon() {
        let afplay = ProcessSnapshot(objectID: 3, pid: 3003, bundleID: nil, executablePath: "/usr/bin/afplay",
                                     parentPID: 500, responsiblePID: 500, isRunningOutput: true, isRunningInput: false)
        let result = plan(input([
            app("com.apple.Terminal", [afplay]),
            app("somedaemond", [daemon(4, "/usr/sbin/somedaemond")]),
        ]))
        XCTAssertEqual(result.byDevice, ["speakers": [TapSpec(appID: "com.apple.Terminal", processObjectIDs: [3])]])
        XCTAssertEqual(result.excluded, ["somedaemond": .systemProcess])
    }
}
