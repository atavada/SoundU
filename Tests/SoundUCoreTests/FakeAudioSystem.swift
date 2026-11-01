import CoreAudio
import Foundation
@testable import SoundUCore

/// In-memory `AudioSystem` for tests. Records every call; never runs an IOProc block
/// unless a test calls `invokeIO(aggregate:)`.
final class FakeAudioSystem: AudioSystem, @unchecked Sendable {
    enum Call: Equatable {
        case createTap(processObjectIDs: [AudioObjectID], name: String)
        case destroyTap(AudioObjectID)
        case createAggregate(deviceUID: String, tapUIDs: [String])
        case setAggregateTaps(AudioObjectID, tapUIDs: [String])
        case destroyAggregate(AudioObjectID)
        case startIO(aggregate: AudioObjectID)
        case stopIO(aggregate: AudioObjectID)
        case setNoDuck(AudioObjectID, Bool)
        case setBufferFrameSize(AudioObjectID, UInt32)
    }

    private let lock = NSLock()
    private var _processes: [ProcessSnapshot] = []
    private var _devices: [OutputDevice] = []
    private var _defaultUID: String?
    private var _calls: [Call] = []
    private var _failingTapNames: Set<String> = []
    private var _failingAggregateDeviceUIDs: Set<String> = []
    private var _deviceInputStreams: [String: Int] = [:]
    private var aggregateLayout: [AudioObjectID: (deviceUID: String, taps: Int)] = [:]
    private var _runningBundleIDs: Set<String> = []
    private var _noDuckSupported = true
    private var _noDuckSucceeds = true
    private var _latencyMs: Double = 10
    private var observers: [UUID: @Sendable (AudioSystemChange) -> Void] = [:]
    private var ioBlocks: [UInt: (aggregate: AudioObjectID, block: AudioDeviceIOBlock)] = [:]
    private var nextObjectID: AudioObjectID = 1000

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    // MARK: - Test controls

    var processList: [ProcessSnapshot] {
        get { locked { _processes } }
        set { locked { _processes = newValue } }
    }
    var devices: [OutputDevice] {
        get { locked { _devices } }
        set { locked { _devices = newValue } }
    }
    var defaultUID: String? {
        get { locked { _defaultUID } }
        set { locked { _defaultUID = newValue } }
    }
    var failingTapNames: Set<String> {
        get { locked { _failingTapNames } }
        set { locked { _failingTapNames = newValue } }
    }
    var failingAggregateDeviceUIDs: Set<String> {
        get { locked { _failingAggregateDeviceUIDs } }
        set { locked { _failingAggregateDeviceUIDs = newValue } }
    }
    /// Device UID → the device's own input stream count (default 0).
    var deviceInputStreams: [String: Int] {
        get { locked { _deviceInputStreams } }
        set { locked { _deviceInputStreams = newValue } }
    }
    var runningBundleIDs: Set<String> {
        get { locked { _runningBundleIDs } }
        set { locked { _runningBundleIDs = newValue } }
    }
    var noDuckSupported: Bool {
        get { locked { _noDuckSupported } }
        set { locked { _noDuckSupported = newValue } }
    }
    var noDuckSucceeds: Bool {
        get { locked { _noDuckSucceeds } }
        set { locked { _noDuckSucceeds = newValue } }
    }
    var latencyMs: Double {
        get { locked { _latencyMs } }
        set { locked { _latencyMs = newValue } }
    }
    var calls: [Call] { locked { _calls } }
    var activeIOCount: Int { locked { ioBlocks.count } }

    /// Delivers `change` to every live observer, synchronously.
    func send(_ change: AudioSystemChange) {
        for observer in locked({ Array(observers.values) }) { observer(change) }
    }

    /// Runs the IOProc blocks registered on `aggregate` once, with empty buffer lists.
    func invokeIO(aggregate: AudioObjectID) {
        var input = AudioBufferList()
        var output = AudioBufferList()
        invokeIO(aggregate: aggregate, input: &input, output: &output)
    }

    /// Runs the IOProc blocks registered on `aggregate` once with the given buffers.
    func invokeIO(aggregate: AudioObjectID, input: UnsafePointer<AudioBufferList>,
                  output: UnsafeMutablePointer<AudioBufferList>) {
        let blocks = locked { ioBlocks.values.filter { $0.aggregate == aggregate }.map(\.block) }
        var time = AudioTimeStamp()
        for block in blocks { block(&time, input, &time, output, &time) }
    }

    // MARK: - AudioSystem

    func processes() -> [ProcessSnapshot] { processList }
    func outputDevices() -> [OutputDevice] { devices }
    func defaultOutputDeviceUID() -> String? { defaultUID }

    func observe(_ change: @escaping @Sendable (AudioSystemChange) -> Void) -> AnyObject {
        let id = UUID()
        locked { observers[id] = change }
        return Token { [weak self] in self?.locked { _ = self?.observers.removeValue(forKey: id) } }
    }

    func createTap(processObjectIDs: [AudioObjectID], name: String) throws -> (tapID: AudioObjectID, uid: String) {
        try locked {
            _calls.append(.createTap(processObjectIDs: processObjectIDs, name: name))
            if _failingTapNames.contains(name) {
                throw AudioSystemError("create tap \(name)", kAudioHardwareIllegalOperationError)
            }
            return (allocateID(), UUID().uuidString)
        }
    }

    func destroyTap(_ tap: AudioObjectID) { record(.destroyTap(tap)) }

    func createAggregate(deviceUID: String, tapUIDs: [String]) throws -> AudioObjectID {
        try locked {
            _calls.append(.createAggregate(deviceUID: deviceUID, tapUIDs: tapUIDs))
            if _failingAggregateDeviceUIDs.contains(deviceUID) {
                throw AudioSystemError("create aggregate on \(deviceUID)", kAudioHardwareBadDeviceError)
            }
            let agg = allocateID()
            aggregateLayout[agg] = (deviceUID, tapUIDs.count)
            return agg
        }
    }

    func setAggregateTaps(_ agg: AudioObjectID, tapUIDs: [String]) throws {
        locked {
            _calls.append(.setAggregateTaps(agg, tapUIDs: tapUIDs))
            aggregateLayout[agg]?.taps = tapUIDs.count
        }
    }

    func destroyAggregate(_ agg: AudioObjectID) {
        locked {
            _calls.append(.destroyAggregate(agg))
            aggregateLayout[agg] = nil
        }
    }

    func inputStreamCount(aggregate: AudioObjectID) -> Int {
        locked {
            guard let layout = aggregateLayout[aggregate] else { return 0 }
            return (_deviceInputStreams[layout.deviceUID] ?? 0) + layout.taps
        }
    }

    func startIO(aggregate: AudioObjectID, block: @escaping AudioDeviceIOBlock) throws -> AudioDeviceIOProcID {
        locked {
            _calls.append(.startIO(aggregate: aggregate))
            let key = UInt(allocateID())
            ioBlocks[key] = (aggregate, block)
            return unsafeBitCast(UnsafeRawPointer(bitPattern: key)!, to: AudioDeviceIOProcID.self)
        }
    }

    func stopIO(aggregate: AudioObjectID, proc: AudioDeviceIOProcID) {
        locked {
            _calls.append(.stopIO(aggregate: aggregate))
            ioBlocks.removeValue(forKey: UInt(bitPattern: unsafeBitCast(proc, to: UnsafeRawPointer.self)))
        }
    }

    func isNoDuckSupported() -> Bool { noDuckSupported }

    func setNoDuck(subDevicesOf agg: AudioObjectID, _ on: Bool) -> Bool {
        locked {
            _calls.append(.setNoDuck(agg, on))
            return _noDuckSucceeds
        }
    }

    func setBufferFrameSize(_ dev: AudioObjectID, _ frames: UInt32) throws {
        record(.setBufferFrameSize(dev, frames))
    }

    func addedLatencyMs(aggregate: AudioObjectID) -> Double { latencyMs }

    func isProcessRunning(bundleID: String) -> Bool {
        locked { _runningBundleIDs.contains(bundleID) || _processes.contains { $0.bundleID == bundleID } }
    }

    // MARK: - Helpers

    private func record(_ call: Call) { locked { _calls.append(call) } }

    /// Caller holds `lock`.
    private func allocateID() -> AudioObjectID {
        nextObjectID += 1
        return nextObjectID
    }

    private final class Token {
        private let onDeinit: () -> Void
        init(_ onDeinit: @escaping () -> Void) { self.onDeinit = onDeinit }
        deinit { onDeinit() }
    }
}
