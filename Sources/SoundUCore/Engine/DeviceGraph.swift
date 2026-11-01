import CoreAudio
import CSoundUDSP
import Foundation
import os

/// The live audio graph on one output device: process taps, one private aggregate
/// (the device plus the taps) and an IOProc that runs the C mixer. `AudioEngine` gives each
/// app its own graph (one tap); the multi-tap paths stay general but are not used by it. The aggregate's input
/// buffers are the physical device's own input streams (if any) followed by one per tap,
/// in tap-list order: tap i is read from input buffer `base + i`. The device's own input
/// streams are switched off for the IOProc (IOProcStreamUsage), so its microphone is never opened.
///
/// Not thread-safe; owned by `AudioEngine`. Only the IOProc block runs on the IO thread,
/// and it touches nothing but `state` and `counter`.
final class DeviceGraph {
    struct Tap {
        var appID: String
        var processObjectIDs: [AudioObjectID]
        var tapID: AudioObjectID
        var uid: String
        var slot: UInt32
    }

    typealias Failure = (appID: String, error: String)
    private static let log = Logger(subsystem: "com.example.SoundU", category: "Engine")
    /// Volume and mute for an app, used when its slot is configured.
    typealias Gains = (String) -> (volume: Float, muted: Bool)

    let deviceUID: String
    /// The physical output device (for the `AudioDeviceDuck` fallback).
    let deviceID: AudioObjectID
    let aggregate: AudioObjectID
    private(set) var taps: [Tap]
    private let system: AudioSystem
    private let state: UnsafeMutablePointer<SUMixState>
    private let counter: UnsafeMutablePointer<SUCounter>
    private var proc: AudioDeviceIOProcID?
    /// Input buffers before the first tap's (the physical device's own input streams).
    private var base = 0
    /// Deactivated slots and the callback count at deactivation; reusable once IO moved on.
    private var retired: [(slot: UInt32, count: UInt64)] = []

    /// IO callbacks run so far.
    var callbackCount: UInt64 { su_counter_load(counter) }

    /// Creates taps for `specs` (failures reported, apps left untapped), the aggregate,
    /// configures the mixer and starts IO. Returns nil when nothing could be started.
    static func start(system: AudioSystem, device: OutputDevice?, deviceUID: String, specs: [TapSpec],
                      bufferFrames: UInt32, gains: Gains) -> (graph: DeviceGraph?, failures: [Failure]) {
        var failures: [Failure] = []
        var taps: [Tap] = []
        for spec in specs {
            guard taps.count < Int(SU_MAX_SLOTS) else {
                failures.append((spec.appID, "no free mixer slot")); continue
            }
            do {
                let (tapID, uid) = try system.createTap(processObjectIDs: spec.processObjectIDs,
                                                        name: tapName(spec.appID))
                taps.append(Tap(appID: spec.appID, processObjectIDs: spec.processObjectIDs,
                                tapID: tapID, uid: uid, slot: UInt32(taps.count)))
            } catch {
                failures.append((spec.appID, "\(error)"))
            }
        }
        guard !taps.isEmpty else { return (nil, failures) }

        let aggregate: AudioObjectID
        do {
            aggregate = try system.createAggregate(deviceUID: deviceUID, tapUIDs: taps.map(\.uid))
        } catch {
            for tap in taps { system.destroyTap(tap.tapID) }
            return (nil, failures + taps.map { ($0.appID, "\(error)") })
        }
        do {
            try system.setBufferFrameSize(aggregate, bufferFrames)
        } catch {
            Self.log.error("\(error, privacy: .public); keeping the default buffer size (higher latency)")
        }

        let graph = DeviceGraph(system: system, deviceUID: deviceUID, deviceID: device?.id ?? AudioObjectID(kAudioObjectUnknown),
                                aggregate: aggregate, sampleRate: device?.sampleRate ?? 48_000, taps: taps)
        graph.base = graph.currentBase(tapCount: taps.count)
        for (index, tap) in taps.enumerated() { graph.configure(tap, buffer: graph.base + index, gains: gains) }
        do {
            graph.proc = try system.startIO(aggregate: aggregate,
                                           inputStreamUsage: graph.inputStreamUsage(tapCount: taps.count),
                                           block: makeIOBlock(state: graph.state, counter: graph.counter))
        } catch {
            graph.teardown()
            return (nil, failures + taps.map { ($0.appID, "\(error)") })
        }
        return (graph, failures)
    }

    private init(system: AudioSystem, deviceUID: String, deviceID: AudioObjectID, aggregate: AudioObjectID,
                 sampleRate: Double, taps: [Tap]) {
        self.system = system
        self.deviceUID = deviceUID
        self.deviceID = deviceID
        self.aggregate = aggregate
        self.taps = taps
        state = .allocate(capacity: 1)
        su_mix_init(state, sampleRate > 0 ? sampleRate : 48_000)
        counter = .allocate(capacity: 1)
        su_counter_init(counter)
    }

    static func tapName(_ appID: String) -> String { "SoundU-\(getpid())-\(appID)" }

    /// The IOProc: render the mix, count the callback. Nothing else (no allocation, locks or calls).
    private static func makeIOBlock(state: UnsafeMutablePointer<SUMixState>,
                                    counter: UnsafeMutablePointer<SUCounter>) -> AudioDeviceIOBlock {
        nonisolated(unsafe) let state = state
        nonisolated(unsafe) let counter = counter
        return { _, input, _, output, _ in
            let first = output.pointee.mBuffers
            let bytesPerFrame = first.mNumberChannels * UInt32(MemoryLayout<Float>.size)
            let frames = output.pointee.mNumberBuffers > 0 && bytesPerFrame > 0 ? first.mDataByteSize / bytesPerFrame : 0
            su_render(state, input, output, frames)
            su_counter_increment(counter)
        }
    }

    // MARK: - Updates

    /// Brings the tap list in line with `specs` without recreating the aggregate: unchanged
    /// taps stay, an app whose process set changed gets a new tap in the same position,
    /// removed apps' taps go, new apps are appended. Apps whose input buffer index changes
    /// move to a fresh mixer slot; their old slots are switched off before the HAL changes the
    /// tap list, so no slot ever reads another app's buffer (moved apps get a few-ms gap).
    /// Returns apps that could not be tapped (left untapped), and `stop` when the caller must
    /// tear the graph down: no tap is left, or the tap-list change failed (the old list, which
    /// may include an app that must no longer be tapped, would otherwise stay live).
    func update(_ specs: [TapSpec], gains: Gains) -> (failures: [Failure], stop: Bool) {
        let wanted = Dictionary(specs.map { ($0.appID, $0.processObjectIDs) }, uniquingKeysWith: { a, _ in a })
        let existing = Set(taps.map(\.appID))
        let added = specs.filter { !existing.contains($0.appID) }
        let changed = taps.contains { wanted[$0.appID] != $0.processObjectIDs }
        guard changed || !added.isEmpty else { return ([], false) }

        var failures: [Failure] = []
        var created: [Tap] = []   // new tap objects, destroyed again if the update fails
        func makeTap(_ appID: String, _ ids: [AudioObjectID]) -> Tap? {
            do {
                let (tapID, uid) = try system.createTap(processObjectIDs: ids, name: Self.tapName(appID))
                let tap = Tap(appID: appID, processObjectIDs: ids, tapID: tapID, uid: uid, slot: 0)
                created.append(tap)
                return tap
            } catch {
                failures.append((appID, "\(error)"))
                return nil
            }
        }

        // Candidates in final order; `oldIndex` is set for entries that may keep their slot.
        var candidates: [(tap: Tap, oldIndex: Int?)] = []
        for (index, tap) in taps.enumerated() {
            guard let ids = wanted[tap.appID] else { continue }
            if ids == tap.processObjectIDs {
                candidates.append((tap, index))
            } else if var replacement = makeTap(tap.appID, ids) {
                replacement.slot = tap.slot
                candidates.append((replacement, index))
            }
        }
        for spec in added {
            if let tap = makeTap(spec.appID, spec.processObjectIDs) { candidates.append((tap, nil)) }
        }

        // Assign slots: keep a slot only if the buffer index is unchanged.
        var free = freeSlots()
        var final: [Tap] = []
        var fresh: Set<String> = []
        for (tap, oldIndex) in candidates {
            var tap = tap
            if oldIndex != final.count {
                guard !free.isEmpty else { failures.append((tap.appID, "no free mixer slot")); continue }
                tap.slot = free.removeFirst()
                fresh.insert(tap.appID)
            }
            final.append(tap)
        }

        let finalUIDs = Set(final.map(\.uid))
        if final.isEmpty {
            created.forEach { system.destroyTap($0.tapID) }
            return (failures, true)
        }

        // Before the HAL change: switch off removed slots and slots whose buffer index changes.
        let keptSlots = Set(final.filter { !fresh.contains($0.appID) }.map(\.slot))
        retire(taps.map(\.slot).filter { !keptSlots.contains($0) })

        let oldBase = base
        let listChanged = final.map(\.uid) != taps.map(\.uid)
        if listChanged {
            do {
                try system.setAggregateTaps(aggregate, tapUIDs: final.map(\.uid))
            } catch {
                created.forEach { system.destroyTap($0.tapID) }
                return (failures + created.map { ($0.appID, "\(error)") }, true)
            }
        }

        // If the device's own input stream count changed, every tap's buffer moved: give the
        // remaining kept taps fresh slots too (a live slot's buffer index cannot be changed).
        let newBase = currentBase(tapCount: final.count)
        if newBase != base {
            var moved: [UInt32] = []
            for i in final.indices where !fresh.contains(final[i].appID) {
                guard !free.isEmpty else {
                    Self.log.error("no free mixer slot to move \(final[i].appID, privacy: .public) to its new buffer")
                    continue
                }
                moved.append(final[i].slot)
                final[i].slot = free.removeFirst()
                fresh.insert(final[i].appID)
            }
            retire(moved)
            base = newBase
        }
        // The stream layout changed: keep the device's own input streams off for our IOProc.
        if listChanged || base != oldBase, base > 0 || oldBase > 0, let proc {
            let usage = inputStreamUsage(tapCount: final.count) ?? Array(repeating: true, count: final.count)
            system.setInputStreamUsage(aggregate: aggregate, proc: proc, usage)
        }

        for (index, tap) in final.enumerated() where fresh.contains(tap.appID) {
            configure(tap, buffer: base + index, gains: gains)
        }
        for tap in taps where !finalUIDs.contains(tap.uid) { system.destroyTap(tap.tapID) }
        for tap in created where !finalUIDs.contains(tap.uid) { system.destroyTap(tap.tapID) }
        taps = final
        return (failures, false)
    }

    /// Deactivates `slots`; they become reusable once IO has moved on (see `freeSlots`).
    private func retire(_ slots: [UInt32]) {
        let count = callbackCount
        for slot in slots {
            su_slot_deactivate(state, slot)
            retired.append((slot, count))
        }
    }

    /// Slots neither in use nor recently deactivated. A deactivated slot is reusable once
    /// at least one full IO cycle has run since (the C contract for `su_slot_configure`).
    private func freeSlots() -> [UInt32] {
        let count = callbackCount
        retired.removeAll { count >= $0.count + 2 }
        let busy = Set(taps.map(\.slot)).union(retired.map(\.slot))
        return (0..<UInt32(SU_MAX_SLOTS)).filter { !busy.contains($0) }
    }

    private func configure(_ tap: Tap, buffer: Int, gains: Gains) {
        let (volume, muted) = gains(tap.appID)
        su_slot_configure(state, tap.slot, UInt32(buffer), volume, muted ? 1 : 0)
    }

    /// Input streams our IOProc uses: the device's own (the microphone, if any) off, taps on.
    /// Nil when the device has no input streams (all on, the default).
    private func inputStreamUsage(tapCount: Int) -> [Bool]? {
        base > 0 ? Array(repeating: false, count: base) + Array(repeating: true, count: tapCount) : nil
    }

    private func currentBase(tapCount: Int) -> Int {
        max(0, system.inputStreamCount(aggregate: aggregate) - tapCount)
    }

    // MARK: - Per-app controls (atomics only)

    func set(appID: String, volume: Float, muted: Bool) {
        for tap in taps where tap.appID == appID { su_slot_set(state, tap.slot, volume, muted ? 1 : 0) }
    }

    func takePeaks() -> [String: Float] {
        Dictionary(taps.map { ($0.appID, su_slot_take_peak(state, $0.slot)) }, uniquingKeysWith: max)
    }

    // MARK: - Teardown

    /// Stops IO; `beforeDestroy` runs while the aggregate still exists (to clear 'nodk').
    /// Then destroys the aggregate and taps and frees the mixer. The graph is unusable afterwards.
    func teardown(beforeDestroy: () -> Void = {}) {
        if let proc { system.stopIO(aggregate: aggregate, proc: proc) }
        proc = nil
        beforeDestroy()
        system.destroyAggregate(aggregate)
        for tap in taps { system.destroyTap(tap.tapID) }
        taps = []
        state.deallocate()
        counter.deallocate()
    }
}
