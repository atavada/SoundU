// Call Guard policy: which call apps are in a call, whether SoundU's output is exempt from
// ducking ('nodk'), and what the pill shows. Pure; the controller supplies the inputs.

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

/// A call app (by owner ID) is in a call while any of its processes runs both input and output.
/// The exemption is skipped while VoiceOver runs, so VoiceOver's own ducking keeps working.
public func evaluateCallGuard(enabled: Bool, callApps: Set<String>, grouping: Grouping,
                              voiceOverRunning: Bool, exemptionAvailable: Bool) -> CallGuardDecision {
    let inCall = grouping.apps.filter { app in
        callApps.contains(app.id) && app.processes.contains { $0.isRunningInput && $0.isRunningOutput }
    }
    let status: CallGuardStatus
    if !exemptionAvailable {
        status = .unavailable
    } else if !enabled {
        status = .off
    } else if let call = inCall.first {
        status = .protecting(appName: call.name)
    } else {
        status = .on
    }
    return CallGuardDecision(status: status, activeCallApps: Set(inCall.map(\.id)),
                             exemptOutput: enabled && exemptionAvailable && !voiceOverRunning)
}
