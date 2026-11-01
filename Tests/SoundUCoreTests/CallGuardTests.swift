import CoreAudio
import XCTest
@testable import SoundUCore

final class CallGuardTests: XCTestCase {
    // MARK: - Fixtures

    private let whatsAppID = "net.whatsapp.WhatsApp"
    private let faceTimeID = "com.apple.FaceTime"
    private let callApps = Set(GlobalSettings().callApps)

    private let whatsApp = RunningApp(pid: 300, bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp")
    private let faceTime = RunningApp(pid: 400, bundleID: "com.apple.FaceTime", name: "FaceTime")
    private let spotify = RunningApp(pid: 500, bundleID: "com.spotify.client", name: "Spotify")

    private func proc(_ objectID: AudioObjectID, _ owner: RunningApp, output: Bool, input: Bool) -> ProcessSnapshot {
        ProcessSnapshot(objectID: objectID, pid: owner.pid, bundleID: owner.bundleID,
                        executablePath: "/Applications/\(owner.name).app/Contents/MacOS/\(owner.name)",
                        parentPID: 1, responsiblePID: owner.pid, isRunningOutput: output, isRunningInput: input)
    }

    private func evaluate(_ procs: [ProcessSnapshot], running: [RunningApp], enabled: Bool = true,
                          voiceOver: Bool = false, available: Bool = true) -> CallGuardDecision {
        evaluateCallGuard(enabled: enabled, callApps: callApps,
                          grouping: groupProcesses(procs, runningApps: running),
                          voiceOverRunning: voiceOver, exemptionAvailable: available)
    }

    /// WhatsApp in a call (one process running input and output) while Spotify plays.
    private var whatsAppCall: [ProcessSnapshot] {
        [proc(1, whatsApp, output: true, input: true), proc(2, spotify, output: true, input: false)]
    }

    // MARK: - Tests

    func testNoCallIsOnAndExempt() {
        let procs = [
            proc(1, whatsApp, output: true, input: false), // a voice note, not a call
            proc(2, spotify, output: true, input: false),
        ]
        let decision = evaluate(procs, running: [whatsApp, spotify])

        XCTAssertEqual(decision, CallGuardDecision(status: .on, activeCallApps: [], exemptOutput: true))
    }

    func testWhatsAppCallProtectsAndLocks() {
        let decision = evaluate(whatsAppCall, running: [whatsApp, spotify])

        XCTAssertEqual(decision.status, .protecting(appName: "WhatsApp"))
        XCTAssertEqual(decision.activeCallApps, [whatsAppID])
        XCTAssertTrue(decision.exemptOutput)
    }

    func testFaceTimeCallViaAvconferenced() {
        let avconferenced = ProcessSnapshot(objectID: 7, pid: 900, bundleID: "com.apple.avconferenced",
                                            executablePath: "/usr/libexec/avconferenced", parentPID: 1,
                                            responsiblePID: 900, isRunningOutput: true, isRunningInput: true)
        let procs = [
            proc(3, faceTime, output: false, input: false), // the FaceTime UI itself is silent
            avconferenced,
            proc(2, spotify, output: true, input: false),
        ]
        let decision = evaluate(procs, running: [faceTime, spotify])

        XCTAssertEqual(decision.status, .protecting(appName: "FaceTime"))
        XCTAssertEqual(decision.activeCallApps, [faceTimeID])
        XCTAssertTrue(decision.exemptOutput)
    }

    func testVoiceOverDisablesExemptionButKeepsLock() {
        let decision = evaluate(whatsAppCall, running: [whatsApp, spotify], voiceOver: true)

        XCTAssertFalse(decision.exemptOutput)
        XCTAssertEqual(decision.activeCallApps, [whatsAppID])
        XCTAssertEqual(decision.status, .protecting(appName: "WhatsApp"))
    }

    func testDisabledStillNeverTouchesCall() {
        let decision = evaluate(whatsAppCall, running: [whatsApp, spotify], enabled: false)

        XCTAssertEqual(decision, CallGuardDecision(status: .off, activeCallApps: [whatsAppID], exemptOutput: false))
    }

    func testUnavailableWhenNoMechanism() {
        let decision = evaluate(whatsAppCall, running: [whatsApp, spotify], available: false)

        XCTAssertEqual(decision, CallGuardDecision(status: .unavailable, activeCallApps: [whatsAppID],
                                                   exemptOutput: false))
    }

    func testAppOutsideCallListIsNeverACall() {
        let zoom = RunningApp(pid: 700, bundleID: "us.zoom.xos", name: "zoom.us")
        let decision = evaluate([proc(1, zoom, output: true, input: true)], running: [zoom])

        XCTAssertEqual(decision, CallGuardDecision(status: .on, activeCallApps: [], exemptOutput: true))
    }
}
