import CoreAudio
import Foundation
import os

/// Identifies one live graph: an app on an output device.
public struct GraphKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var deviceUID: String
    public var appID: String

    public init(deviceUID: String, appID: String) {
        self.deviceUID = deviceUID
        self.appID = appID
    }

    public static func < (a: GraphKey, b: GraphKey) -> Bool { (a.deviceUID, a.appID) < (b.deviceUID, b.appID) }
    public var description: String { "\(appID) on \(deviceUID)" }
}

public enum EngineEvent: Equatable, Sendable {
    /// The app could not be tapped; it keeps playing directly.
    case tapFailed(appID: String, error: String)
    /// IO got no callbacks after start and none was ever seen this run: Audio Capture permission
    /// is not granted (yet). The graph was torn down, so its apps play directly again.
    case permissionPending
    /// A graph for `appID` started on device `uid`.
    case deviceStarted(uid: String, appID: String, addedLatencyMs: Double)
    /// The first IO callbacks were seen: Audio Capture permission is granted.
    case ioConfirmed(uid: String)
    /// IO stopped advancing after permission was confirmed; the graph was torn down (the app
    /// plays directly) and that app on that device is retried after a 5 s back-off.
    case ioStalled(uid: String, appID: String)
}

/// Turns a `RoutingPlan` into live graphs: one `DeviceGraph` (tap + private aggregate + IOProc)
/// per (output device, app). Changing an aggregate's tap list restarts IO for every tap on it,
/// so apps never share one: starting, stopping or re-tapping an app touches only its own
/// aggregate. Volume changes touch only the mixer's atomics.
@MainActor
public final class AudioEngine {
    public var onEvent: (@Sendable (EngineEvent) -> Void)?

    /// Set when a graph got no IO callbacks within the IO timeout before any IO was ever seen.
    /// While set, `apply` starts no new graphs; the controller clears it to retry on the next `apply`.
    public var permissionPending = false

    /// Aggregate device of each running graph.
    public var runningAggregates: [GraphKey: AudioObjectID] { graphs.mapValues(\.aggregate) }

    /// Fallback for the 'nodk' exemption: `AudioDeviceDuck` on the physical device.
    var duckFallback: (AudioObjectID, Bool) -> Void = { device, exempt in
        _ = HAL.audioDeviceDuck()?(device, exempt ? 0.9999999 : 1.0, nil, 0)
    }

    private static let log = Logger(subsystem: "com.example.SoundU", category: "Engine")
    private let system: AudioSystem
    private let bufferFrames: UInt32
    private let ioTimeout: Duration
    /// Clock for the IO watchdog; replaceable in tests.
    var now: () -> ContinuousClock.Instant = { .now }
    private static let stallBackoff: Duration = .seconds(5)
    /// Cap for the growing back-off of a pinned app's graph.
    private static let maxStallBackoff: Duration = .seconds(60)
    private var graphs: [GraphKey: DeviceGraph] = [:]
    private var volumes: [String: (volume: Float, muted: Bool)] = [:]
    /// IO progress of each running graph (callback count and when it last changed).
    private var watches: [GraphKey: (count: UInt64, since: ContinuousClock.Instant, bluetooth: Bool)] = [:]
    /// When a stalled graph may be started again.
    private var backoff: [GraphKey: ContinuousClock.Instant] = [:]
    /// Stalls in a row with no IO seen in between, per pinned graph (System Sounds is always
    /// routed, so on a dead device it would otherwise restart every few seconds forever).
    private var stallStreak: [GraphKey: Int] = [:]
    private var duckingExempt = false
    /// Physical device UIDs on which the exemption is currently set. 'nodk' belongs to
    /// (this process, physical device), so graphs on one device share it.
    private var noDuckDevices: Set<String> = []
    /// IO callbacks have been seen once this run, so permission is granted.
    private var permissionConfirmed = false

    /// `ioTimeout`: how long a graph's IO may make no progress before it is torn down.
    public init(system: AudioSystem, bufferFrames: UInt32 = 128, ioTimeout: Duration = .seconds(2)) {
        self.system = system
        self.bufferFrames = bufferFrames
        self.ioTimeout = ioTimeout
    }

    // MARK: - Plan

    public func apply(_ plan: RoutingPlan) {
        var wanted: [GraphKey: TapSpec] = [:]
        for (uid, specs) in plan.byDevice {
            for spec in specs { wanted[GraphKey(deviceUID: uid, appID: spec.appID)] = spec }
        }
        // A leaving graph on a device that keeps or gains graphs stops after the starts, so the
        // device never briefly has no graph and 'nodk' is never cleared and set again.
        let wantedDevices = Set(wanted.keys.map(\.deviceUID))
        var deferred: [(GraphKey, DeviceGraph)] = []
        for (key, graph) in graphs.sorted(by: { $0.key < $1.key }) where wanted[key] == nil {
            if wantedDevices.contains(key.deviceUID) { deferred.append((key, graph)) } else { stop(key, graph) }
        }
        let stalled = stalledGraphs

        let devices = Dictionary(system.outputDevices().map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, spec) in wanted.sorted(by: { $0.key < $1.key }) {
            if let graph = graphs[key] {
                let (failures, stopGraph) = graph.update([spec], gains: gain)
                report(failures)
                if stopGraph { stop(key, graph) }
            } else if !permissionPending && !stalled.contains(key) {
                start(key, device: devices[key.deviceUID], spec: spec)
            }
        }
        for (key, graph) in deferred { stop(key, graph) }
    }

    private func start(_ key: GraphKey, device: OutputDevice?, spec: TapSpec) {
        let (graph, failures) = DeviceGraph.start(system: system, device: device, deviceUID: key.deviceUID,
                                                  specs: [spec], bufferFrames: bufferFrames, gains: gain)
        report(failures)
        guard let graph else { return }
        graphs[key] = graph
        if duckingExempt && !noDuckDevices.contains(key.deviceUID) {
            setNoDuck(graph, true)
            noDuckDevices.insert(key.deviceUID)
        }
        let latency = system.addedLatencyMs(aggregate: graph.aggregate)
        Self.log.info("started \(key, privacy: .public): added latency \(latency) ms")
        onEvent?(.deviceStarted(uid: key.deviceUID, appID: key.appID, addedLatencyMs: latency))
        watches[key] = (0, now(), device?.isBluetooth ?? false)
    }

    /// Clears the exemption only when this is the last graph on its physical device.
    private func stop(_ key: GraphKey, _ graph: DeviceGraph) {
        graphs[key] = nil
        watches[key] = nil
        let last = !graphs.keys.contains { $0.deviceUID == key.deviceUID }
        graph.teardown {
            if last && noDuckDevices.remove(key.deviceUID) != nil { setNoDuck(graph, false) }
        }
    }

    public func stopAll() {
        for (key, graph) in graphs.sorted(by: { $0.key < $1.key }) { stop(key, graph) }
    }

    private func report(_ failures: [DeviceGraph.Failure]) {
        for failure in failures {
            Self.log.error("tap failed for \(failure.appID, privacy: .public): \(failure.error, privacy: .public)")
            onEvent?(.tapFailed(appID: failure.appID, error: failure.error))
        }
    }

    // MARK: - IO watchdog

    /// Graphs (app on device) that stalled less than 5 s ago; `apply` does not restart them until then.
    public var stalledGraphs: Set<GraphKey> {
        let now = now()
        return Set(backoff.filter { $0.value > now }.keys)
    }

    /// IO watchdog; the controller runs it on every re-plan (at least once a second). The first
    /// callbacks seen confirm permission (`.ioConfirmed`). A graph whose callback count has not
    /// advanced for the IO timeout is torn down (its apps play directly): `.permissionPending`
    /// if no IO was ever seen this run (Bluetooth devices get one extra period first, they can
    /// be slow to start), else `.ioStalled` and that graph (app on device) backs off for 5 s.
    /// A pinned app's graph backs off 5, 10, 20 … up to 60 s while it keeps stalling without IO.
    public func checkIO() {
        let now = now()
        backoff = backoff.filter { $0.value > now }
        for (key, graph) in graphs.sorted(by: { $0.key < $1.key }) {
            guard var watch = watches[key] else { continue }
            let count = graph.callbackCount
            if count != watch.count {
                watch.count = count
                watch.since = now
                watches[key] = watch
            }
            if count > 0 { stallStreak[key] = nil }
            if count > 0 && !permissionConfirmed {
                permissionConfirmed = true
                onEvent?(.ioConfirmed(uid: key.deviceUID))
            }
            let limit = !permissionConfirmed && watch.bluetooth ? ioTimeout * 2 : ioTimeout
            guard now - watch.since >= limit else { continue }
            stop(key, graph)
            if permissionConfirmed {
                var wait = Self.stallBackoff
                if key.appID == SystemSounds.appID {
                    let streak = stallStreak[key, default: 0]
                    wait = min(Self.stallBackoff * (1 << min(streak, 4)), Self.maxStallBackoff)
                    stallStreak[key] = streak + 1
                }
                Self.log.error("IO stalled for \(key, privacy: .public); retrying in \(wait, privacy: .public)")
                backoff[key] = now + wait
                onEvent?(.ioStalled(uid: key.deviceUID, appID: key.appID))
            } else {
                Self.log.error("no IO callbacks for \(key, privacy: .public): Audio Capture permission pending")
                permissionPending = true
                onEvent?(.permissionPending)
            }
        }
    }

    // MARK: - Volume and meters

    public func set(appID: String, volume: Float, muted: Bool) {
        volumes[appID] = (volume, muted)
        for graph in graphs.values { graph.set(appID: appID, volume: volume, muted: muted) }
    }

    private func gain(_ appID: String) -> (volume: Float, muted: Bool) {
        volumes[appID] ?? (1, false)
    }

    public func takePeaks() -> [String: Float] {
        graphs.values.reduce(into: [:]) { result, graph in
            result.merge(graph.takePeaks(), uniquingKeysWith: max)
        }
    }

    // MARK: - Call Guard exemption

    /// Applies the 'nodk' exemption once per physical device with running graphs; graphs
    /// started later set it on start if their device lacks it, and the last graph on a device
    /// clears it when it stops.
    public func setDuckingExempt(_ on: Bool) {
        duckingExempt = on
        var firstGraph: [String: DeviceGraph] = [:]
        for (key, graph) in graphs.sorted(by: { $0.key > $1.key }) { firstGraph[key.deviceUID] = graph }
        for (uid, graph) in firstGraph.sorted(by: { $0.key < $1.key }) where noDuckDevices.contains(uid) != on {
            setNoDuck(graph, on)
            if on { noDuckDevices.insert(uid) } else { noDuckDevices.remove(uid) }
        }
    }

    private func setNoDuck(_ graph: DeviceGraph, _ on: Bool) {
        if !system.setNoDuck(subDevicesOf: graph.aggregate, on) {
            duckFallback(graph.deviceID, on)
        }
    }
}
