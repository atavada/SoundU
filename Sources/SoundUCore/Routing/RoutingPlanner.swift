import CoreAudio
import Foundation

/// Everything the planner needs to decide which apps are tapped onto which output device.
public struct PlannerInput: Sendable {
    public var grouping: Grouping
    public var settings: SettingsSnapshot
    public var devices: [OutputDevice]
    public var defaultDeviceUID: String
    /// Apps whose call is currently active.
    public var activeCallApps: Set<String>
    /// App ID → last time any of its processes was running output.
    public var lastPlayed: [String: Date]
    public var now: Date
    public var selfBundleID: String
    /// Apps whose tap could not be created.
    public var failedApps: Set<String>

    public init(grouping: Grouping, settings: SettingsSnapshot, devices: [OutputDevice],
                defaultDeviceUID: String, activeCallApps: Set<String>, lastPlayed: [String: Date],
                now: Date, selfBundleID: String, failedApps: Set<String>) {
        self.grouping = grouping
        self.settings = settings
        self.devices = devices
        self.defaultDeviceUID = defaultDeviceUID
        self.activeCallApps = activeCallApps
        self.lastPlayed = lastPlayed
        self.now = now
        self.selfBundleID = selfBundleID
        self.failedApps = failedApps
    }
}

/// Why an app that would otherwise be routed is left untapped.
public enum Exclusion: Equatable, Sendable {
    case callInProgress, sharedWithCall, soundU, tapFailed
    /// Every process is a system daemon (under /usr/ or /System/), e.g. systemsoundserverd
    /// playing notification sounds. Never routed and never shown.
    case systemProcess
    /// Set by the controller while Audio Capture permission is pending; never emitted by `plan`.
    case permissionPending
}

public struct TapSpec: Equatable, Hashable, Sendable {
    public var appID: String
    /// Sorted ascending.
    public var processObjectIDs: [AudioObjectID]

    public init(appID: String, processObjectIDs: [AudioObjectID]) {
        self.appID = appID
        self.processObjectIDs = processObjectIDs
    }
}

public struct RoutingPlan: Equatable, Sendable {
    /// Device UID → taps sorted by `appID`. Devices with no taps are omitted.
    public var byDevice: [String: [TapSpec]]
    public var excluded: [String: Exclusion]

    public init(byDevice: [String: [TapSpec]], excluded: [String: Exclusion]) {
        self.byDevice = byDevice
        self.excluded = excluded
    }
}

/// How long an app stays routed after it stops playing.
let lingerInterval: TimeInterval = 5

/// Decides which apps are tapped onto which device. An app is a candidate while it is playing
/// or played less than 5 s ago; other apps are absent from the plan (neither routed nor excluded).
/// Candidates are excluded, in precedence order, when they are SoundU itself, in an active call,
/// made only of system daemons (call services excepted), failed to tap, or left with no processes after dropping those shared with an active call app.
/// Routed apps go to their saved output device when present, else to the default device.
public func plan(_ input: PlannerInput) -> RoutingPlan {
    let deviceUIDs = Set(input.devices.map(\.uid))
    let callShared = Set(input.grouping.sharedOwners.compactMap { objectID, owners in
        owners.isDisjoint(with: input.activeCallApps) ? nil : objectID
    })

    var byDevice: [String: [TapSpec]] = [:]
    var excluded: [String: Exclusion] = [:]
    for app in input.grouping.apps {
        let lingering = input.lastPlayed[app.id].map { input.now.timeIntervalSince($0) < lingerInterval } ?? false
        guard app.isPlaying || lingering else { continue }

        if app.id == input.selfBundleID { excluded[app.id] = .soundU; continue }
        if input.activeCallApps.contains(app.id) { excluded[app.id] = .callInProgress; continue }
        if app.processes.allSatisfy(isSystemDaemon) { excluded[app.id] = .systemProcess; continue }
        if input.failedApps.contains(app.id) { excluded[app.id] = .tapFailed; continue }

        let objectIDs = app.processes.map(\.objectID).filter { !callShared.contains($0) }.sorted()
        if objectIDs.isEmpty { excluded[app.id] = .sharedWithCall; continue }

        let saved = input.settings.setting(for: app.id).outputDeviceUID
        let device = saved.flatMap { deviceUIDs.contains($0) ? $0 : nil } ?? input.defaultDeviceUID
        byDevice[device, default: []].append(TapSpec(appID: app.id, processObjectIDs: objectIDs))
    }
    return RoutingPlan(byDevice: byDevice.mapValues { $0.sorted { $0.appID < $1.appID } }, excluded: excluded)
}

/// A process whose executable is part of the OS. Call services (avconferenced, callservicesd)
/// are not: they carry FaceTime and Phone audio.
func isSystemDaemon(_ p: ProcessSnapshot) -> Bool {
    (p.executablePath.hasPrefix("/usr/") || p.executablePath.hasPrefix("/System/")) && !CallServices.isCallProcess(p)
}
