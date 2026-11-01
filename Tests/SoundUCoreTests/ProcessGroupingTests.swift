import CoreAudio
import XCTest
@testable import SoundUCore

final class ProcessGroupingTests: XCTestCase {
    // MARK: - Fixtures

    private func proc(_ objectID: AudioObjectID, pid: pid_t, bundleID: String?, exe: String,
                      parent: pid_t = 1, responsible: pid_t? = nil,
                      output: Bool = false, input: Bool = false) -> ProcessSnapshot {
        ProcessSnapshot(objectID: objectID, pid: pid, bundleID: bundleID, executablePath: exe,
                        parentPID: parent, responsiblePID: responsible ?? pid,
                        isRunningOutput: output, isRunningInput: input)
    }

    private let chrome = RunningApp(pid: 100, bundleID: "com.google.Chrome", name: "Google Chrome")
    private let safari = RunningApp(pid: 200, bundleID: "com.apple.Safari", name: "Safari")
    private let whatsApp = RunningApp(pid: 300, bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp")
    private let faceTime = RunningApp(pid: 400, bundleID: "com.apple.FaceTime", name: "FaceTime")
    private let phone = RunningApp(pid: 410, bundleID: "com.apple.mobilephone", name: "Phone")
    private let spotify = RunningApp(pid: 500, bundleID: "com.spotify.client", name: "Spotify")
    private let music = RunningApp(pid: 600, bundleID: "com.apple.Music", name: "Music")

    private func app(_ id: String, in grouping: Grouping) -> AudioApp? {
        grouping.apps.first { $0.id == id }
    }

    // MARK: - Grouping

    func testChromeHelpersGroupIntoChrome() throws {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let procs = [
            proc(1, pid: 101, bundleID: "com.google.Chrome.helper", exe: helper, parent: 100, responsible: 100, output: true),
            proc(2, pid: 102, bundleID: "com.google.Chrome.helper", exe: helper, parent: 100, responsible: 100),
            proc(3, pid: 103, bundleID: "com.google.Chrome.helper.renderer", exe: helper, parent: 100, responsible: 100),
        ]
        let grouping = groupProcesses(procs, runningApps: [chrome, safari])

        XCTAssertEqual(grouping.apps.map(\.id), ["com.google.Chrome"])
        let chromeApp = try XCTUnwrap(app("com.google.Chrome", in: grouping))
        XCTAssertEqual(chromeApp.name, "Google Chrome")
        XCTAssertEqual(chromeApp.processes.map(\.objectID), [1, 2, 3])
        XCTAssertTrue(chromeApp.isPlaying)
        XCTAssertTrue(grouping.sharedOwners.isEmpty)
    }

    func testChromeHelperFallsBackToBundlePrefix() {
        // Responsible PID unknown (0) and parent is launchd: rule 4 still finds Chrome.
        let procs = [proc(1, pid: 101, bundleID: "com.google.Chrome.helper", exe: "/x/Google Chrome Helper",
                          parent: 1, responsible: 0)]
        let grouping = groupProcesses(procs, runningApps: [chrome])
        XCTAssertEqual(grouping.apps.map(\.id), ["com.google.Chrome"])
    }

    func testWebKitGPUServesSafari() {
        let procs = [
            proc(1, pid: 200, bundleID: "com.apple.Safari", exe: "/Applications/Safari.app/Contents/MacOS/Safari"),
            proc(2, pid: 201, bundleID: "com.apple.WebKit.GPU",
                 exe: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
                 parent: 1, responsible: 200, output: true),
        ]
        let grouping = groupProcesses(procs, runningApps: [safari, chrome])

        XCTAssertEqual(grouping.apps.map(\.id), ["com.apple.Safari"])
        XCTAssertEqual(app("com.apple.Safari", in: grouping)?.processes.map(\.objectID), [1, 2])
        XCTAssertEqual(app("com.apple.Safari", in: grouping)?.isPlaying, true)
    }

    func testWhatsAppGroupsItsProcesses() {
        let procs = [
            proc(1, pid: 300, bundleID: "net.whatsapp.WhatsApp", exe: "/Applications/WhatsApp.app/Contents/MacOS/WhatsApp",
                 output: true, input: true),
            proc(2, pid: 301, bundleID: "com.apple.WebKit.GPU", exe: "/x/com.apple.WebKit.GPU", parent: 1, responsible: 300),
            proc(3, pid: 302, bundleID: "net.whatsapp.WhatsApp.ServiceExtension", exe: "/x/ServiceExtension",
                 parent: 300, responsible: 300),
        ]
        let grouping = groupProcesses(procs, runningApps: [whatsApp, safari])

        XCTAssertEqual(grouping.apps.map(\.id), ["net.whatsapp.WhatsApp"])
        XCTAssertEqual(app("net.whatsapp.WhatsApp", in: grouping)?.name, "WhatsApp")
        XCTAssertEqual(app("net.whatsapp.WhatsApp", in: grouping)?.processes.map(\.objectID), [1, 2, 3])
    }

    func testAvconferencedBelongsToFaceTimeAndIsSharedWithPhone() {
        let procs = [
            proc(7, pid: 700, bundleID: "com.apple.avconferenced", exe: "/usr/libexec/avconferenced",
                 output: true, input: true),
        ]
        let grouping = groupProcesses(procs, runningApps: [faceTime, phone, spotify])

        XCTAssertEqual(grouping.apps.map(\.id), ["com.apple.FaceTime"])
        XCTAssertEqual(app("com.apple.FaceTime", in: grouping)?.name, "FaceTime")
        XCTAssertEqual(app("com.apple.FaceTime", in: grouping)?.processes.map(\.objectID), [7])
        XCTAssertEqual(grouping.sharedOwners[7], ["com.apple.FaceTime", "com.apple.mobilephone"])
    }

    func testAvconferencedWithNoCallAppRunningIsFaceTime() {
        let procs = [proc(7, pid: 700, bundleID: "com.apple.avconferenced", exe: "/usr/libexec/avconferenced")]
        let grouping = groupProcesses(procs, runningApps: [spotify])

        XCTAssertEqual(grouping.apps.map(\.id), ["com.apple.FaceTime"])
        XCTAssertEqual(grouping.apps.first?.name, "FaceTime")
        XCTAssertNil(grouping.sharedOwners[7])
    }

    func testCallservicesdIsFaceTime() {
        let procs = [proc(8, pid: 800, bundleID: nil, exe: "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd")]
        let grouping = groupProcesses(procs, runningApps: [faceTime])
        XCTAssertEqual(grouping.apps.map(\.id), ["com.apple.FaceTime"])
        XCTAssertEqual(grouping.apps.first?.processes.map(\.objectID), [8])
    }

    func testResponsibleAndParentChainDisagreeIsShared() {
        // Launched by Chrome (parent) but attributed to Safari (responsible): never split.
        let procs = [proc(9, pid: 900, bundleID: "com.example.tool", exe: "/x/tool", parent: 100, responsible: 200)]
        let grouping = groupProcesses(procs, runningApps: [chrome, safari])

        XCTAssertEqual(grouping.apps.map(\.id), ["com.apple.Safari"])
        XCTAssertEqual(grouping.apps.flatMap(\.processes).map(\.objectID), [9])
        XCTAssertEqual(grouping.sharedOwners[9], ["com.apple.Safari", "com.google.Chrome"])
    }

    func testParentChainWalksThroughAudioProcesses() {
        let procs = [
            proc(1, pid: 901, bundleID: nil, exe: "/x/a", parent: 100, responsible: 901),
            proc(2, pid: 902, bundleID: nil, exe: "/x/b", parent: 901, responsible: 902),
        ]
        let grouping = groupProcesses(procs, runningApps: [chrome])
        XCTAssertEqual(grouping.apps.map(\.id), ["com.google.Chrome"])
        XCTAssertEqual(grouping.apps.first?.processes.map(\.objectID), [1, 2])
    }

    func testUnknownDaemonIsItsOwnApp() {
        let procs = [
            proc(1, pid: 950, bundleID: "com.example.audiodaemon", exe: "/usr/local/bin/audiod", output: true),
            proc(2, pid: 951, bundleID: nil, exe: "/usr/local/bin/beeper"),
        ]
        let grouping = groupProcesses(procs, runningApps: [chrome])

        XCTAssertEqual(Set(grouping.apps.map(\.id)), ["com.example.audiodaemon", "beeper"])
        XCTAssertEqual(app("com.example.audiodaemon", in: grouping)?.name, "audiodaemon")
        XCTAssertEqual(app("beeper", in: grouping)?.name, "beeper")
        XCTAssertEqual(app("com.example.audiodaemon", in: grouping)?.isPlaying, true)
        XCTAssertEqual(app("beeper", in: grouping)?.isPlaying, false)
    }

    func testSpotifyAndMusicStandalone() {
        let procs = [
            proc(1, pid: 500, bundleID: "com.spotify.client", exe: "/Applications/Spotify.app/Contents/MacOS/Spotify", output: true),
            proc(2, pid: 600, bundleID: "com.apple.Music", exe: "/System/Applications/Music.app/Contents/MacOS/Music"),
        ]
        let grouping = groupProcesses(procs, runningApps: [spotify, music, chrome])

        XCTAssertEqual(grouping.apps.map(\.id), ["com.apple.Music", "com.spotify.client"])
        XCTAssertEqual(grouping.apps.map(\.name), ["Music", "Spotify"])
        XCTAssertEqual(app("com.spotify.client", in: grouping)?.processes.map(\.objectID), [1])
        XCTAssertEqual(app("com.apple.Music", in: grouping)?.processes.map(\.objectID), [2])
        XCTAssertTrue(grouping.sharedOwners.isEmpty)
    }

    // MARK: - Monitor

    private func spotifyProc(output: Bool) -> ProcessSnapshot {
        proc(1, pid: 500, bundleID: "com.spotify.client", exe: "/x/Spotify", output: output)
    }

    func testMonitorStartsWithCurrentGrouping() {
        let system = FakeAudioSystem()
        system.processList = [spotifyProc(output: true)]
        let monitor = ProcessMonitor(system: system, runningApps: { [spotify] in [spotify] })
        monitor.start()
        XCTAssertEqual(monitor.current().apps.map(\.id), ["com.spotify.client"])
        XCTAssertEqual(monitor.current().apps.first?.isPlaying, true)
    }

    func testMonitorRereadsAfterDebouncedBurst() {
        let system = FakeAudioSystem()
        system.processList = [spotifyProc(output: false)]
        let monitor = ProcessMonitor(system: system, runningApps: { [spotify] in [spotify] })
        let updates = Locked<[Grouping]>([])
        let changed = expectation(description: "onChange after burst")
        monitor.onChange = { grouping in
            updates.withValue { $0.append(grouping) }
            if grouping.apps.first?.isPlaying == true { changed.fulfill() }
        }
        monitor.start()
        let afterStart = updates.withValue { $0.count }

        // IsRunningOutput flip arrives as `.processes` (no process-list change).
        system.processList = [spotifyProc(output: true)]
        for _ in 0..<5 { system.send(.processes) }

        wait(for: [changed], timeout: 2)
        XCTAssertEqual(updates.withValue { $0.count }, afterStart + 1, "burst coalesced into one update")
        XCTAssertEqual(monitor.current().apps.first?.isPlaying, true)
    }

    func testMonitorIgnoresDeviceChanges() {
        let system = FakeAudioSystem()
        system.processList = [spotifyProc(output: false)]
        let monitor = ProcessMonitor(system: system, runningApps: { [spotify] in [spotify] })
        monitor.start()
        system.processList = [spotifyProc(output: true)]
        system.send(.devices)
        system.send(.defaultOutput)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(monitor.current().apps.first?.isPlaying, false)
    }
}

/// Minimal lock box for collecting values from `@Sendable` callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
