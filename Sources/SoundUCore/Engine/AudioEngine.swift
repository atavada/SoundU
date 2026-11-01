import CoreAudio
import Foundation
import os

public enum EngineEvent: Equatable, Sendable {
    /// The app could not be tapped; it keeps playing directly.
    case tapFailed(appID: String, error: String)
    /// IO got no callbacks after start: Audio Capture permission is not granted (yet).
    /// The graph was torn down, so its apps play directly again.
    case permissionPending
    case deviceStarted(uid: String, addedLatencyMs: Double)
}

/// Turns a `RoutingPlan` into live graphs: one `DeviceGraph` (taps + private aggregate +
/// IOProc) per output device. Volume changes touch only the mixer's atomics.
@MainActor
public final class AudioEngine {
    public var onEvent: (@Sendable (EngineEvent) -> Void)?

    /// Set when a graph got no IO callbacks within the permission timeout. While set, `apply`
    /// starts no new graphs; the controller clears it to retry on the next `apply`.
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
    private let permissionTimeout: Duration
    private var graphs: [String: DeviceGraph] = [:]
    private var volumes: [String: (volume: Float, muted: Bool)] = [:]
    private var duckingExempt = false
    /// IO callbacks have been seen once, so permission is granted; stop checking.
    private var permissionConfirmed = false

    public init(system: AudioSystem, bufferFrames: UInt32 = 128, permissionTimeout: Duration = .seconds(2)) {
        self.system = system
        self.bufferFrames = bufferFrames
        self.permissionTimeout = permissionTimeout
    }

    // MARK: - Plan

    public func apply(_ plan: RoutingPlan) {
        for (uid, graph) in graphs where plan.byDevice[uid] == nil { stop(graph) }

        let devices = Dictionary(system.outputDevices().map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        for (uid, specs) in plan.byDevice.sorted(by: { $0.key < $1.key }) where !specs.isEmpty {
            if let graph = graphs[uid] {
                let (failures, empty) = graph.update(specs, gains: gain)
                report(failures)
                if empty { stop(graph) }
            } else if !permissionPending {
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
        if !permissionConfirmed { schedulePermissionCheck(graph) }
    }

    private func stop(_ graph: DeviceGraph) {
        graphs[graph.deviceUID] = nil
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

    // MARK: - Permission

    private func schedulePermissionCheck(_ graph: DeviceGraph) {
        let timeout = permissionTimeout
        Task { [weak self, weak graph] in
            try? await Task.sleep(for: timeout)
            guard let self, let graph, self.graphs[graph.deviceUID] === graph else { return }
            self.checkPermission(graph)
        }
    }

    private func checkPermission(_ graph: DeviceGraph) {
        guard !permissionConfirmed else { return }
        if graph.callbackCount > 0 {
            permissionConfirmed = true
            return
        }
        Self.log.error("no IO callbacks on \(graph.deviceUID, privacy: .public): Audio Capture permission pending")
        stop(graph)
        permissionPending = true
        onEvent?(.permissionPending)
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
