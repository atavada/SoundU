import AppKit
import CoreAudio
import Foundation
import Observation
import os

public enum PermissionState: Equatable, Sendable {
    case unknown, pending, granted
}

public enum StripState: Equatable, Sendable {
    case routed
    /// Routed but silent; released when the 5 s linger expires.
    case lingering
    /// Untouched because `callApp` is in a call.
    case locked(callApp: String)
    case notRouted(Exclusion)
    /// Tapping failed; the app plays directly.
    case error(String)
}

/// One channel strip as the panel shows it.
public struct AppStrip: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var icon: NSImage?
    public var volume: Float
    public var muted: Bool
    /// Saved preference (nil = default device), even when that device is absent.
    public var outputDeviceUID: String?
    public var state: StripState

    public init(id: String, name: String, icon: NSImage?, volume: Float, muted: Bool,
                outputDeviceUID: String?, state: StripState) {
        self.id = id
        self.name = name
        self.icon = icon
        self.volume = volume
        self.muted = muted
        self.outputDeviceUID = outputDeviceUID
        self.state = state
    }
}

/// Glue between the HAL, the planner, the engine and the UI: keeps strips, devices and
/// permission state current, re-plans on every change, persists settings and drives meters.
@MainActor
@Observable
public final class SoundUController {
    public private(set) var apps: [AppStrip] = []
    public private(set) var devices: [OutputDevice] = []
    public private(set) var defaultDeviceUID: String?
    public private(set) var permission: PermissionState = .unknown
    /// Latest meter peak per app ID, 0...1, updated at 30 Hz. Kept apart from `apps` so meter
    /// updates only redraw the views that read them.
    public private(set) var levels: [String: Float] = [:]

    /// Global preferences the Settings window edits; mirrors `settings.global` so views observe
    /// it without redrawing on every per-app change.
    public private(set) var global: GlobalSettings

    /// What the Call Guard pill and the menu-bar dot show; recomputed on every re-plan.
    public private(set) var callGuard: CallGuardStatus = .off

    /// Upper fader limit (100–200 %).
    public var boostCeiling: Float { global.boostCeiling }

    @ObservationIgnored let engine: AudioEngine
    @ObservationIgnored private let system: AudioSystem
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let monitor: ProcessMonitor
    @ObservationIgnored private let selfBundleID: String
    @ObservationIgnored private var settings: SettingsSnapshot
    @ObservationIgnored private var grouping = Grouping()
    @ObservationIgnored private var lastPlayed: [String: Date] = [:]
    /// App ID → tap error, kept while the app stays a routing candidate.
    @ObservationIgnored private var tapErrors: [String: String] = [:]
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var observation: AnyObject?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// Whether `AudioDeviceDuck` resolves; replaceable in tests.
    @ObservationIgnored var duckFallbackAvailable: () -> Bool = { HAL.audioDeviceDuck() != nil }
    /// 'nodk' settable or `AudioDeviceDuck` present; computed once in `start()`.
    @ObservationIgnored private var exemptionAvailable = false
    /// Last exemption handed to the engine (the engine starts with none).
    @ObservationIgnored private var duckingExempt = false
    /// Call apps in a call → when each last ran input (see `updateCalls`).
    @ObservationIgnored private var calls: [String: Date] = [:]
    /// Clock for call and linger timing; replaceable in tests.
    @ObservationIgnored var now: () -> Date = Date.init

    private static let log = Logger(subsystem: "com.example.SoundU", category: "Controller")
    private static let saveDelay: Duration = .milliseconds(500)
    private static let replanInterval: Duration = .seconds(1)
    private static let meterInterval: Duration = .seconds(1.0 / 30)

    public convenience init(system: AudioSystem = CoreAudioSystem(), store: SettingsStore = .standard) {
        self.init(system: system, store: store, runningApps: ProcessMonitor.workspaceApps,
                  selfBundleID: Bundle.main.bundleIdentifier ?? "com.example.SoundU",
                  ioTimeout: .seconds(2))
    }

    init(system: AudioSystem, store: SettingsStore, runningApps: @escaping @Sendable () -> [RunningApp],
         selfBundleID: String, ioTimeout: Duration) {
        self.system = system
        self.store = store
        self.selfBundleID = selfBundleID
        settings = store.load()
        global = settings.global
        monitor = ProcessMonitor(system: system, runningApps: runningApps)
        engine = AudioEngine(system: system, ioTimeout: ioTimeout)
    }

    // MARK: - Lifecycle

    /// Starts monitoring and routing. Calling it again is a no-op.
    public func start() {
        guard loops.isEmpty else { return }
        engine.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        for (appID, _) in settings.apps { pushGain(appID) }
        exemptionAvailable = system.isNoDuckSupported() || duckFallbackAvailable()

        observation = system.observe { [weak self] change in
            guard change != .processes else { return }
            Task { @MainActor in self?.refreshDevices() }
        }
        monitor.onChange = { [weak self] grouping in
            Task { @MainActor in self?.update(grouping) }
        }
        monitor.start()
        grouping = monitor.current()
        devices = system.outputDevices()
        defaultDeviceUID = system.defaultOutputDeviceUID()
        replan()

        loops = [
            repeating(every: Self.replanInterval) { $0.replan() },
            repeating(every: Self.meterInterval) { $0.updateLevels() },
        ]
    }

    /// Saves settings, then stops every graph (apps play directly again). For tests and the
    /// headless command; the app uses `prepareForTermination()` when it quits.
    public func shutdown() {
        prepareForTermination()
        engine.stopAll()
    }

    /// Quit path: saves settings now and stops loops and observers, but makes no HAL calls —
    /// stopping IO can block, and the private aggregates, `.mutedWhenTapped` taps and the
    /// per-client 'nodk' exemption all vanish with the process anyway.
    public func prepareForTermination() {
        pendingSave?.cancel()
        save()
        loops.forEach { $0.cancel() }
        loops = []
        monitor.onChange = nil
        observation = nil
        engine.onEvent = nil
    }

    /// Clears the engine's permission flag and re-plans, so graphs are tried again.
    public func retryPermission() {
        engine.permissionPending = false
        permission = .unknown
        replan()
    }

    // MARK: - Strip actions

    public func setVolume(_ appID: String, _ v: Float) {
        change(appID) { $0.volume = min(max(v, 0), settings.global.boostCeiling) }
    }

    public func toggleMute(_ appID: String) {
        change(appID) { $0.muted.toggle() }
    }

    /// `deviceUID == nil` follows the default output device.
    public func setOutput(_ appID: String, deviceUID: String?) {
        change(appID) { $0.outputDeviceUID = deviceUID }
        replan()
    }

    /// Edits the stored setting (not the ceiling-clamped one, so a mute or output change never
    /// writes a clamped volume back).
    private func change(_ appID: String, _ body: (inout AppSetting) -> Void) {
        var stored = settings.apps[appID] ?? .default
        body(&stored)
        settings.apps[appID] = stored
        pushGain(appID)
        let setting = settings.setting(for: appID)
        if let i = apps.firstIndex(where: { $0.id == appID }) {
            apps[i].volume = setting.volume
            apps[i].muted = setting.muted
            apps[i].outputDeviceUID = setting.outputDeviceUID
        }
        scheduleSave()
    }

    private func pushGain(_ appID: String) {
        let setting = settings.setting(for: appID)
        engine.set(appID: appID, volume: setting.volume, muted: setting.muted)
    }

    // MARK: - Global settings

    /// Sets the fader ceiling (clamped to 1.0...2.0). Louder apps play at the ceiling; their
    /// saved volumes are kept, so raising the ceiling again restores them.
    public func setBoostCeiling(_ ceiling: Float) {
        changeGlobal { $0.boostCeiling = GlobalSettings.clampCeiling(ceiling) }
        for appID in settings.apps.keys { pushGain(appID) }
        for i in apps.indices { apps[i].volume = settings.setting(for: apps[i].id).volume }
    }

    /// Persists the flag only; registering with `SMAppService` is the app's job.
    public func setLaunchAtLogin(_ on: Bool) { changeGlobal { $0.launchAtLogin = on } }

    public func setCallGuardEnabled(_ on: Bool) {
        changeGlobal { $0.callGuardEnabled = on }
        replanIfStarted()
    }

    public func setCallApps(_ bundleIDs: [String]) {
        changeGlobal { $0.callApps = bundleIDs }
        replanIfStarted()
    }

    public func resetCallApps() { setCallApps(GlobalSettings().callApps) }

    public func markFirstRunDone() { changeGlobal { $0.firstRunDone = true } }

    private func changeGlobal(_ body: (inout GlobalSettings) -> Void) {
        body(&settings.global)
        if settings.global != global { global = settings.global }
        scheduleSave()
    }

    // MARK: - Settings persistence

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        do {
            try store.save(settings)
        } catch {
            Self.log.error("Saving settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Inputs

    private func update(_ grouping: Grouping) {
        self.grouping = grouping
        replan()
    }

    private func refreshDevices() {
        let devices = system.outputDevices()
        if devices != self.devices { self.devices = devices }
        let uid = system.defaultOutputDeviceUID()
        if uid != defaultDeviceUID { defaultDeviceUID = uid }
        replan()
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .permissionPending:
            permission = .pending
            replan()
        case .deviceStarted:
            break
        case .ioConfirmed:
            if permission != .granted { permission = .granted }
        case .ioStalled:
            replan()
        case .tapFailed(let appID, let error):
            tapErrors[appID] = error
            replan()
        }
    }

    // MARK: - Planning

    /// Call Guard changes show at once instead of on the next timed re-plan.
    private func replanIfStarted() {
        if !loops.isEmpty { replan() }
    }

    private func callGuardDecision(now: Date) -> CallGuardDecision {
        calls = updateCalls(calls, callApps: Set(settings.global.callApps), grouping: grouping, now: now)
        let enabled = settings.global.callGuardEnabled
        // Only matters when the exemption could be set.
        let voiceOver = enabled && exemptionAvailable && grouping.apps.contains { app in
            app.processes.contains { $0.bundleID == "com.apple.VoiceOver" }
        }
        return evaluateCallGuard(enabled: enabled, activeCallApps: Set(calls.keys), grouping: grouping,
                                 voiceOverRunning: voiceOver, exemptionAvailable: exemptionAvailable)
    }

    /// Everything the planner needs right now; nil when there is no default output device.
    private func plannerInput(now: Date, activeCallApps: Set<String>) -> PlannerInput? {
        guard let defaultDeviceUID else { return nil }
        return PlannerInput(grouping: grouping, settings: settings, devices: devices,
                            defaultDeviceUID: defaultDeviceUID, activeCallApps: activeCallApps,
                            lastPlayed: lastPlayed, now: now, selfBundleID: selfBundleID,
                            failedApps: Set(tapErrors.keys))
    }

    private func replan() {
        let now = now()
        for app in grouping.apps where app.isPlaying { lastPlayed[app.id] = now }
        lastPlayed = lastPlayed.filter { now.timeIntervalSince($0.value) < lingerInterval }

        let decision = callGuardDecision(now: now)
        if decision.status != callGuard { callGuard = decision.status }
        // Before `apply`, so graphs started now get the exemption as they start.
        if decision.exemptOutput != duckingExempt {
            duckingExempt = decision.exemptOutput
            engine.setDuckingExempt(duckingExempt)
        }

        let input = plannerInput(now: now, activeCallApps: decision.activeCallApps)
        let routing = input.map(plan) ?? RoutingPlan(byDevice: [:], excluded: [:])
        // A failed app is retried once it stops being a candidate (silent past the linger).
        tapErrors = tapErrors.filter { routing.excluded[$0.key] == .tapFailed }
        engine.checkIO()
        engine.apply(routing)
        rebuildStrips(routing, activeCallApps: decision.activeCallApps)
    }

    private func rebuildStrips(_ routing: RoutingPlan, activeCallApps: Set<String>) {
        let routed = Set(routing.byDevice.values.joined().map(\.appID))
        let stalled = engine.stalledDevices
        let onStalledDevice = Set(routing.byDevice.filter { stalled.contains($0.key) }.values.joined().map(\.appID))

        let strips = grouping.apps.compactMap { app -> AppStrip? in
            let state: StripState
            if activeCallApps.contains(app.id) {
                // Locked even when the planner did not list it (a silent call app).
                state = .locked(callApp: app.id)
            } else if let exclusion = routing.excluded[app.id] {
                state = stripState(app, exclusion, activeCallApps)
            } else if onStalledDevice.contains(app.id) {
                state = .error("The output device stopped responding; retrying shortly")
            } else if routed.contains(app.id) {
                state = permission == .pending ? .notRouted(.permissionPending)
                    : app.isPlaying ? .routed : .lingering
            } else {
                return nil
            }
            let setting = settings.setting(for: app.id)
            return AppStrip(id: app.id, name: app.name, icon: icon(app), volume: setting.volume,
                            muted: setting.muted, outputDeviceUID: setting.outputDeviceUID,
                            state: state)
        }

        func rank(_ s: AppStrip) -> Int {
            switch s.state {
            case .routed: 0
            case .lingering: 1
            default: 2
            }
        }
        let sorted = strips.sorted { (rank($0), $0.name, $0.id) < (rank($1), $1.name, $1.id) }
        if sorted != apps { apps = sorted }
    }

    private func stripState(_ app: AudioApp, _ exclusion: Exclusion, _ activeCallApps: Set<String>) -> StripState {
        switch exclusion {
        case .callInProgress:
            return .locked(callApp: app.id)
        case .sharedWithCall:
            let callApp = app.processes
                .compactMap { grouping.sharedOwners[$0.objectID] }
                .joined()
                .first { activeCallApps.contains($0) }
            return .locked(callApp: callApp ?? app.id)
        case .tapFailed:
            return .error(tapErrors[app.id] ?? "Could not tap this app")
        case .soundU, .permissionPending:
            return .notRouted(exclusion)
        }
    }

    /// The owner's icon: the process whose bundle ID is the app's, else the responsible process.
    private func icon(_ app: AudioApp) -> NSImage? {
        if let cached = icons[app.id] { return cached }
        let owner = app.processes.first { $0.bundleID == app.id }?.pid ?? app.processes.first?.responsiblePID
        guard let owner, let image = NSRunningApplication(processIdentifier: owner)?.icon else { return nil }
        icons[app.id] = image
        return image
    }

    // MARK: - Meters

    private func updateLevels() {
        let metered = apps.filter { $0.state == .routed || $0.state == .lingering }.map(\.id)
        let peaks = engine.takePeaks()
        let next = Dictionary(uniqueKeysWithValues: metered.map { ($0, peaks[$0] ?? 0) })
        if next != levels { levels = next }
    }

    private func repeating(every interval: Duration,
                           _ body: @escaping @MainActor (SoundUController) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                body(self)
            }
        }
    }
}
