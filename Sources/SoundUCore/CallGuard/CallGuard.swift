// Call Guard policy: which call apps are in a call, whether SoundU's output is exempt from
// ducking ('nodk'), and what the pill shows. Pure; the controller supplies the inputs.

import Foundation

public enum CallGuardStatus: Equatable, Sendable {
    case off, on, protecting(appName: String), unavailable
}

public struct CallGuardDecision: Equatable, Sendable {
    public var status: CallGuardStatus
    /// Call apps (owner IDs) in a call now. Filled even when Call Guard is off or unavailable:
    /// SoundU never touches a call regardless.
    public var activeCallApps: Set<String>
    /// Opt SoundU's output out of ducking. On whenever SoundU plays, not only during calls.
    public var exemptOutput: Bool

    public init(status: CallGuardStatus, activeCallApps: Set<String>, exemptOutput: Bool) {
        self.status = status
        self.activeCallApps = activeCallApps
        self.exemptOutput = exemptOutput
    }
}

/// How long a call survives without input (mic mute, route change, hold, HAL restart).
let callInputGrace: TimeInterval = 5

/// Whether `app` is one of `callApps`: by owner ID, by any of its processes' bundle IDs (e.g.
/// `com.apple.avconferenced`, grouped under FaceTime) or by any shared owner of its processes.
func isCallApp(_ app: AudioApp, callApps: Set<String>, grouping: Grouping) -> Bool {
    callApps.contains(app.id) || app.processes.contains { p in
        p.bundleID.map(callApps.contains) == true
            || grouping.sharedOwners[p.objectID].map { !$0.isDisjoint(with: callApps) } == true
    }
}

/// Call state with hysteresis: owner ID → when the call app last ran input. A call app enters a
/// call when one of its processes runs input and output; it stays in the call while it runs
/// output and ran input within the last 5 s.
public func updateCalls(_ previous: [String: Date], callApps: Set<String>, grouping: Grouping,
                        now: Date) -> [String: Date] {
    var calls: [String: Date] = [:]
    for app in grouping.apps where isCallApp(app, callApps: callApps, grouping: grouping) {
        let starts = app.processes.contains { $0.isRunningInput && $0.isRunningOutput }
        guard let last = starts ? now : previous[app.id] else { continue }
        let lastInput = app.processes.contains { $0.isRunningInput } ? now : last
        if app.isPlaying && now.timeIntervalSince(lastInput) <= callInputGrace { calls[app.id] = lastInput }
    }
    return calls
}

/// Status, lock set and exemption for the call apps in a call (`activeCallApps`, from
/// `updateCalls`). The exemption is skipped while VoiceOver runs, so VoiceOver's own ducking works.
public func evaluateCallGuard(enabled: Bool, activeCallApps: Set<String>, grouping: Grouping,
                              voiceOverRunning: Bool, exemptionAvailable: Bool) -> CallGuardDecision {
    let status: CallGuardStatus
    if !exemptionAvailable {
        status = .unavailable
    } else if !enabled {
        status = .off
    } else if let call = grouping.apps.first(where: { activeCallApps.contains($0.id) }) {
        status = .protecting(appName: call.name)
    } else {
        status = .on
    }
    return CallGuardDecision(status: status, activeCallApps: activeCallApps,
                             exemptOutput: enabled && exemptionAvailable && !voiceOverRunning)
}
