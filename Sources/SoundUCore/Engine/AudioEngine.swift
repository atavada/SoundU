import CoreAudio
import Foundation
import os

public enum EngineEvent: Equatable, Sendable {
    /// The app could not be tapped; it keeps playing directly.
    case tapFailed(appID: String, error: String)
    /// IO got no callbacks after start and none was ever seen this run: Audio Capture permission
    /// is not granted (yet). The graph was torn down, so its apps play directly again.
    case permissionPending
    case deviceStarted(uid: String, addedLatencyMs: Double)
    /// The first IO callbacks were seen: Audio Capture permission is granted.
    case ioConfirmed(uid: String)
    /// IO stopped advancing after permission was confirmed; the graph was torn down (its apps
    /// play directly) and the device is retried after a 5 s back-off.
    case ioStalled(uid: String)
}

/// Turns a `RoutingPlan` into live graphs: one `DeviceGraph` (taps + private aggregate +
/// IOProc) per output device. Volume changes touch only the mixer's atomics.
@MainActor
public final class AudioEngine {
    public var onEvent: (@Sendable (EngineEvent) -> Void)?

    /// Set when a graph got no IO callbacks within the IO timeout before any IO was ever seen.
    /// While set, `apply` starts no new graphs; the controller clears it to retry on the next `apply`.
    public var permissionPending = false

    /// Device UID → aggregate device of each running graph.
    public var runningAggregates: [String: AudioObjectID] { graphs.mapValues(\.aggregate) }

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
    private var graphs: [String: DeviceGraph] = [:]
    private var volumes: [String: (volume: Float, muted: Bool)] = [:]
    /// Device UID → IO progress of its running graph (callback count and when it last changed).
    private var watches: [String: (count: UInt64, since: ContinuousClock.Instant, bluetooth: Bool)] = [:]
    /// Device UID → when a stalled device may be started again.
    private var backoff: [String: ContinuousClock.Instant] = [:]
    private var duckingExempt = false
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
        for (uid, graph) in graphs where plan.byDevice[uid] == nil { stop(graph) }
        let stalled = stalledDevices

        let devices = Dictionary(system.outputDevices().map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        for (uid, specs) in plan.byDevice.sorted(by: { $0.key < $1.key }) where !specs.isEmpty {
            if let graph = graphs[uid] {
                let (failures, stopGraph) = graph.update(specs, gains: gain)
                report(failures)
                if stopGraph { stop(graph) }
            } else if !permissionPending && !stalled.contains(uid) {
                start(uid, device: devices[uid], specs: specs)
            }
        }
    }

    private func start(_ uid: String, device: OutputDevice?, specs: [TapSpec]) {
        let (graph, failures) = DeviceGraph.start(system: system, device: device, deviceUID: uid, specs: specs,
                                                  bufferFrames: bufferFrames, gains: gain)
        report(failures)
        guard let graph else { return }
        graphs[uid] = graph
        if duckingExempt { setNoDuck(graph, true) }
        let latency = system.addedLatencyMs(aggregate: graph.aggregate)
        Self.log.info("started \(uid, privacy: .public): \(graph.taps.count) taps, added latency \(latency) ms")
        onEvent?(.deviceStarted(uid: uid, addedLatencyMs: latency))
        watches[uid] = (0, now(), device.map { Self.bluetoothTransports.contains($0.transport) } ?? false)
    }

    private func stop(_ graph: DeviceGraph) {
        graphs[graph.deviceUID] = nil
        watches[graph.deviceUID] = nil
        graph.teardown { if duckingExempt { setNoDuck(graph, false) } }
    }

    public func stopAll() {
        for graph in graphs.values { stop(graph) }
    }

    private func report(_ failures: [DeviceGraph.Failure]) {
        for failure in failures {
            Self.log.error("tap failed for \(failure.appID, privacy: .public): \(failure.error, privacy: .public)")
            onEvent?(.tapFailed(appID: failure.appID, error: failure.error))
        }
    }

    // MARK: - IO watchdog

    private static let bluetoothTransports: Set<UInt32> = [kAudioDeviceTransportTypeBluetooth,
                                                           kAudioDeviceTransportTypeBluetoothLE]

    /// Devices whose graph stalled less than 5 s ago; `apply` does not restart them until then.
    public var stalledDevices: Set<String> {
        let now = now()
        return Set(backoff.filter { $0.value > now }.keys)
    }

    /// IO watchdog; the controller runs it on every re-plan (at least once a second). The first
    /// callbacks seen confirm permission (`.ioConfirmed`). A graph whose callback count has not
    /// advanced for the IO timeout is torn down (its apps play directly): `.permissionPending`
    /// if no IO was ever seen this run (Bluetooth devices get one extra period first, they can
    /// be slow to start), else `.ioStalled` and the device backs off for 5 s.
    public func checkIO() {
        let now = now()
        backoff = backoff.filter { $0.value > now }
        for (uid, graph) in graphs.sorted(by: { $0.key < $1.key }) {
            guard var watch = watches[uid] else { continue }
            let count = graph.callbackCount
            if count != watch.count {
                watch.count = count
                watch.since = now
                watches[uid] = watch
            }
            if count > 0 && !permissionConfirmed {
                permissionConfirmed = true
                onEvent?(.ioConfirmed(uid: uid))
            }
            let limit = !permissionConfirmed && watch.bluetooth ? ioTimeout * 2 : ioTimeout
            guard now - watch.since >= limit else { continue }
            stop(graph)
            if permissionConfirmed {
                Self.log.error("IO stalled on \(uid, privacy: .public); retrying in 5 s")
                backoff[uid] = now + Self.stallBackoff
                onEvent?(.ioStalled(uid: uid))
            } else {
                Self.log.error("no IO callbacks on \(uid, privacy: .public): Audio Capture permission pending")
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

    /// Applies the 'nodk' exemption to every running graph's output sub-devices; graphs started
    /// later get it on start, and each graph clears it when it stops.
    public func setDuckingExempt(_ on: Bool) {
        duckingExempt = on
        for graph in graphs.values { setNoDuck(graph, on) }
    }

    private func setNoDuck(_ graph: DeviceGraph, _ on: Bool) {
        if !system.setNoDuck(subDevicesOf: graph.aggregate, on) {
            duckFallback(graph.deviceID, on)
        }
    }
}
