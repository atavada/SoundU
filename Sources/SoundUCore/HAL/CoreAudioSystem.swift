import AppKit
import CoreAudio
import Foundation
import os

/// Live `AudioSystem` over the Core Audio HAL. Stateless; safe to share across threads.
public final class CoreAudioSystem: AudioSystem {
    private static let log = Logger(subsystem: "com.example.SoundU", category: "HAL")
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    /// Our own private aggregates; hidden from `outputDevices()`.
    static let aggregateUIDPrefix = "SoundU-Agg-"

    /// Drift compensation on each sub-tap (on in the product; off only for latency diagnostics).
    private let tapDriftCompensation: UInt32

    public init(tapDriftCompensation: Bool = true) {
        self.tapDriftCompensation = tapDriftCompensation ? 1 : 0
    }

    // MARK: - Enumeration

    public func processes() -> [ProcessSnapshot] {
        HAL.objectIDs(Self.system, kAudioHardwarePropertyProcessObjectList).compactMap { obj in
            guard let pid = HAL.int32(obj, kAudioProcessPropertyPID), pid > 0 else { return nil }
            let bundleID = HAL.string(obj, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
            let parent = HAL.parentPID(of: pid) ?? 0
            return ProcessSnapshot(
                objectID: obj,
                pid: pid,
                bundleID: bundleID,
                executablePath: HAL.executablePath(of: pid),
                parentPID: parent,
                responsiblePID: HAL.responsiblePID(of: pid) ?? parent,
                isRunningOutput: HAL.uint32(obj, kAudioProcessPropertyIsRunningOutput) == 1,
                isRunningInput: HAL.uint32(obj, kAudioProcessPropertyIsRunningInput) == 1)
        }
    }

    public func outputDevices() -> [OutputDevice] {
        HAL.objectIDs(Self.system, kAudioHardwarePropertyDevices).compactMap { dev in
            let channels = HAL.channelCount(dev, kAudioObjectPropertyScopeOutput)
            guard channels > 0,
                  let uid = HAL.string(dev, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(Self.aggregateUIDPrefix) else { return nil }
            return OutputDevice(
                id: dev,
                uid: uid,
                name: HAL.string(dev, kAudioObjectPropertyName) ?? uid,
                sampleRate: HAL.double(dev, kAudioDevicePropertyNominalSampleRate) ?? 0,
                outputChannels: channels,
                transport: HAL.uint32(dev, kAudioDevicePropertyTransportType) ?? 0)
        }
    }

    public func defaultOutputDeviceUID() -> String? {
        guard let dev = defaultOutputDevice() else { return nil }
        return HAL.string(dev, kAudioDevicePropertyDeviceUID)
    }

    private func defaultOutputDevice() -> AudioObjectID? {
        guard let dev = HAL.uint32(Self.system, kAudioHardwarePropertyDefaultOutputDevice),
              dev != kAudioObjectUnknown else { return nil }
        return dev
    }

    public func observe(_ change: @escaping @Sendable (AudioSystemChange) -> Void) -> AnyObject {
        HALObservation(change)
    }

    // MARK: - Taps and aggregates

    public func createTap(processObjectIDs: [AudioObjectID], name: String) throws -> (tapID: AudioObjectID, uid: String) {
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        desc.name = name
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "create tap \(name)")
        return (tap, desc.uuid.uuidString)
    }

    public func destroyTap(_ tap: AudioObjectID) {
        logIfError(AudioHardwareDestroyProcessTap(tap), "destroy tap \(tap)")
    }

    public func createAggregate(deviceUID: String, tapUIDs: [String]) throws -> AudioObjectID {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundU",
            kAudioAggregateDeviceUIDKey: "\(Self.aggregateUIDPrefix)\(getpid())-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceClockDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: tapUIDs.map {
                [kAudioSubTapDriftCompensationKey: tapDriftCompensation, kAudioSubTapUIDKey: $0] as [String: Any]
            },
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg), "create aggregate on \(deviceUID)")
        if !tapUIDs.isEmpty { waitForInputStreams(agg, tapCount: tapUIDs.count) }
        return agg
    }

    /// Tap input streams appear asynchronously; poll in 10 ms steps, for at most 3 s in total,
    /// until the aggregate has the sub-devices' own input streams (re-read each step, as they
    /// can appear late too) plus one per tap.
    private func waitForInputStreams(_ agg: AudioObjectID, tapCount: Int) {
        let deadline = ContinuousClock.now + .seconds(3)
        var expected = 0
        repeat {
            let own = HAL.objectIDs(agg, kAudioAggregateDevicePropertyActiveSubDeviceList)
                .reduce(0) { $0 + HAL.objectIDs($1, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count }
            expected = own + tapCount
            if inputStreamCount(aggregate: agg) == expected { return }
            usleep(10_000)
        } while ContinuousClock.now < deadline
        Self.log.error("aggregate \(agg) has \(self.inputStreamCount(aggregate: agg)) input streams after 3 s, expected \(expected)")
    }

    public func inputStreamCount(aggregate: AudioObjectID) -> Int {
        HAL.objectIDs(aggregate, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count
    }

    public func setAggregateTaps(_ agg: AudioObjectID, tapUIDs: [String]) throws {
        var addr = HAL.address(kAudioAggregateDevicePropertyTapList)
        var list = tapUIDs as CFArray
        let status = withUnsafeMutablePointer(to: &list) {
            AudioObjectSetPropertyData(agg, &addr, 0, nil, UInt32(MemoryLayout<CFArray>.size), $0)
        }
        try check(status, "set tap list on aggregate \(agg)")
        waitForInputStreams(agg, tapCount: tapUIDs.count)
        // Sub-taps added via the property start without drift compensation.
        for subTap in HAL.objectIDs(agg, kAudioAggregateDevicePropertySubTapList) {
            logIfError(HAL.setUInt32(subTap, kAudioSubTapPropertyDriftCompensation, kAudioObjectPropertyScopeGlobal,
                                     tapDriftCompensation),
                       "enable drift compensation on sub-tap \(subTap)")
        }
    }

    public func destroyAggregate(_ agg: AudioObjectID) {
        logIfError(AudioHardwareDestroyAggregateDevice(agg), "destroy aggregate \(agg)")
    }

    // MARK: - IO

    public func startIO(aggregate: AudioObjectID, inputStreamUsage: [Bool]?,
                        block: @escaping AudioDeviceIOBlock) throws -> AudioDeviceIOProcID {
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil, block), "create IOProc on \(aggregate)")
        guard let proc else { throw AudioSystemError("create IOProc on \(aggregate)", kAudioHardwareUnspecifiedError) }
        // Before start, so streams marked unused (the device's microphone) are never opened.
        if let inputStreamUsage { setInputStreamUsage(aggregate: aggregate, proc: proc, inputStreamUsage) }
        let status = AudioDeviceStart(aggregate, proc)
        if status != noErr {
            AudioDeviceDestroyIOProcID(aggregate, proc)
            throw AudioSystemError("start IO on \(aggregate)", status)
        }
        return proc
    }

    /// `kAudioDevicePropertyIOProcStreamUsage`, input scope: an `AudioHardwareIOProcStreamUsage`
    /// (variable length: `mStreamIsOn` holds one UInt32 per input stream of the device).
    public func setInputStreamUsage(aggregate: AudioObjectID, proc: AudioDeviceIOProcID, _ usage: [Bool]) {
        typealias Usage = AudioHardwareIOProcStreamUsage
        let flagsOffset = MemoryLayout<Usage>.offset(of: \Usage.mStreamIsOn)!
        let size = max(MemoryLayout<Usage>.size, flagsOffset + usage.count * MemoryLayout<UInt32>.stride)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<Usage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self),
                       toByteOffset: MemoryLayout<Usage>.offset(of: \Usage.mIOProc)!, as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(usage.count), toByteOffset: MemoryLayout<Usage>.offset(of: \Usage.mNumberStreams)!,
                       as: UInt32.self)
        for (i, on) in usage.enumerated() {
            raw.storeBytes(of: on ? 1 : 0, toByteOffset: flagsOffset + i * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
        var addr = HAL.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        logIfError(AudioObjectSetPropertyData(aggregate, &addr, 0, nil, UInt32(size), raw),
                   "set input stream usage \(usage.map { $0 ? 1 : 0 }) on \(aggregate)")
    }

    public func stopIO(aggregate: AudioObjectID, proc: AudioDeviceIOProcID) {
        logIfError(AudioDeviceStop(aggregate, proc), "stop IO on \(aggregate)")
        logIfError(AudioDeviceDestroyIOProcID(aggregate, proc), "destroy IOProc on \(aggregate)")
    }

    // MARK: - Call Guard exemption, buffer, latency

    public func isNoDuckSupported() -> Bool {
        guard let dev = defaultOutputDevice() else { return false }
        return HAL.isSettable(dev, HAL.noDuckSelector, kAudioObjectPropertyScopeOutput)
    }

    public func setNoDuck(subDevicesOf agg: AudioObjectID, _ on: Bool) -> Bool {
        let outputs = HAL.objectIDs(agg, kAudioAggregateDevicePropertyActiveSubDeviceList)
            .filter { HAL.channelCount($0, kAudioObjectPropertyScopeOutput) > 0 }
        guard !outputs.isEmpty else { return false }
        var allSet = true
        for dev in outputs {
            let status = HAL.setUInt32(dev, HAL.noDuckSelector, kAudioObjectPropertyScopeOutput, on ? 1 : 0)
            if status != noErr {
                logIfError(status, "set 'nodk'=\(on ? 1 : 0) on \(dev)")
                allSet = false
            }
        }
        return allSet
    }

    public func setBufferFrameSize(_ dev: AudioObjectID, _ frames: UInt32) throws {
        try check(HAL.setUInt32(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, frames),
                  "set buffer frame size \(frames) on \(dev)")
    }

    public func addedLatencyMs(aggregate: AudioObjectID) -> Double {
        let input = kAudioObjectPropertyScopeInput
        guard let rate = HAL.double(aggregate, kAudioDevicePropertyNominalSampleRate), rate > 0 else { return 0 }
        let buffer = HAL.uint32(aggregate, kAudioDevicePropertyBufferFrameSize) ?? 0
        let latency = HAL.uint32(aggregate, kAudioDevicePropertyLatency, input) ?? 0
        let safety = HAL.uint32(aggregate, kAudioDevicePropertySafetyOffset, input) ?? 0
        return Double(2 * buffer + latency + safety) / rate * 1000
    }

    public func isProcessRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            || processes().contains { $0.bundleID == bundleID }
    }

    // MARK: - Errors

    private func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        guard status != noErr else { return }
        let op = operation()
        Self.log.error("\(op, privacy: .public) failed: \(status)")
        throw AudioSystemError(op, status)
    }

    private func logIfError(_ status: OSStatus, _ operation: @autoclosure () -> String) {
        guard status != noErr else { return }
        let op = operation()
        Self.log.error("\(op, privacy: .public) failed: \(status)")
    }
}

/// Listener token returned by `CoreAudioSystem.observe`. Listens on the system object for
/// process-list, device-list and default-output changes, and on every process object for
/// IsRunningOutput/IsRunningInput. Callbacks are delivered on a private serial queue, never
/// on Core Audio's notification thread. Releasing the token removes every listener.
private final class HALObservation: @unchecked Sendable {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    // The HAL notifies 'pir?' (IsRunning) on IO start/stop; it does not notify 'piro'/'piri' (macOS 26.5).
    private static let processSelectors = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput,
                                           kAudioProcessPropertyIsRunningInput]

    private let queue = DispatchQueue(label: "com.example.SoundU.hal-observer")
    private let systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]
    private let processListener: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var observedProcesses: Set<AudioObjectID> = []   // guarded by `lock` (read in deinit)

    init(_ change: @escaping @Sendable (AudioSystemChange) -> Void) {
        processListener = { _, _ in change(.processes) }
        let rescan = Box()
        systemListeners = [
            (HAL.address(kAudioHardwarePropertyProcessObjectList), { _, _ in rescan.run?(); change(.processes) }),
            (HAL.address(kAudioHardwarePropertyDevices), { _, _ in change(.devices) }),
            (HAL.address(kAudioHardwarePropertyDefaultOutputDevice), { _, _ in change(.defaultOutput) }),
        ]
        rescan.run = { [weak self] in self?.syncProcessListeners() }
        for (addr, block) in systemListeners {
            var a = addr
            AudioObjectAddPropertyListenerBlock(Self.system, &a, queue, block)
        }
        // Every sync runs on `queue`, so add/remove calls for one process never interleave.
        queue.sync { syncProcessListeners() }
    }

    deinit {
        for (addr, block) in systemListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(Self.system, &a, queue, block)
        }
        lock.lock()
        let current = observedProcesses
        observedProcesses = []
        lock.unlock()
        for obj in current { setProcessListeners(obj, add: false) }
    }

    private func syncProcessListeners() {
        let now = Set(HAL.objectIDs(Self.system, kAudioHardwarePropertyProcessObjectList))
        lock.lock()
        let added = now.subtracting(observedProcesses)
        let removed = observedProcesses.subtracting(now)
        observedProcesses = now
        lock.unlock()
        for obj in added { setProcessListeners(obj, add: true) }
        for obj in removed { setProcessListeners(obj, add: false) }
    }

    private func setProcessListeners(_ obj: AudioObjectID, add: Bool) {
        for selector in Self.processSelectors {
            var a = HAL.address(selector)
            if add {
                AudioObjectAddPropertyListenerBlock(obj, &a, queue, processListener)
            } else {
                AudioObjectRemovePropertyListenerBlock(obj, &a, queue, processListener)
            }
        }
    }

    /// Breaks the init-order cycle: the system listeners are built before `self` is usable.
    private final class Box: @unchecked Sendable {
        var run: (() -> Void)?
    }
}
