import CoreAudio

/// One Core Audio process object (a process that has an audio client).
public struct ProcessSnapshot: Equatable, Hashable, Sendable {
    public var objectID: AudioObjectID
    public var pid: pid_t
    public var bundleID: String?
    public var executablePath: String
    public var parentPID: pid_t
    public var responsiblePID: pid_t
    public var isRunningOutput: Bool
    public var isRunningInput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String?, executablePath: String,
                parentPID: pid_t, responsiblePID: pid_t, isRunningOutput: Bool, isRunningInput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.parentPID = parentPID
        self.responsiblePID = responsiblePID
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
    }
}

/// A device with at least one output channel.
public struct OutputDevice: Equatable, Hashable, Sendable {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
    public var sampleRate: Double
    public var outputChannels: Int
    public var transport: UInt32

    public init(id: AudioObjectID, uid: String, name: String, sampleRate: Double,
                outputChannels: Int, transport: UInt32) {
        self.id = id
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
        self.outputChannels = outputChannels
        self.transport = transport
    }
}

public enum AudioSystemChange: Equatable, Sendable {
    /// Process list changed, or a process started/stopped running IO.
    case processes
    case devices
    case defaultOutput
}

public struct AudioSystemError: Error, Equatable, CustomStringConvertible {
    public var operation: String
    public var status: OSStatus

    public init(_ operation: String, _ status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var description: String { "\(operation) failed (OSStatus \(status))" }
}

/// Every Core Audio HAL call SoundU makes. `CoreAudioSystem` is the live implementation.
public protocol AudioSystem: AnyObject, Sendable {
    func processes() -> [ProcessSnapshot]
    func outputDevices() -> [OutputDevice]
    func defaultOutputDeviceUID() -> String?
    /// Calls `change` (off Core Audio's notification thread) until the returned token is released.
    func observe(_ change: @escaping @Sendable (AudioSystemChange) -> Void) -> AnyObject

    func createTap(processObjectIDs: [AudioObjectID], name: String) throws -> (tapID: AudioObjectID, uid: String)
    func destroyTap(_ tap: AudioObjectID)
    func createAggregate(deviceUID: String, tapUIDs: [String]) throws -> AudioObjectID
    func setAggregateTaps(_ agg: AudioObjectID, tapUIDs: [String]) throws
    func destroyAggregate(_ agg: AudioObjectID)

    func startIO(aggregate: AudioObjectID, block: @escaping AudioDeviceIOBlock) throws -> AudioDeviceIOProcID
    /// Stops and destroys the IOProc.
    func stopIO(aggregate: AudioObjectID, proc: AudioDeviceIOProcID)

    func isNoDuckSupported() -> Bool
    /// Sets 'nodk' on each output sub-device of `agg`; true only if every set succeeded.
    func setNoDuck(subDevicesOf agg: AudioObjectID, _ on: Bool) -> Bool
    func setBufferFrameSize(_ dev: AudioObjectID, _ frames: UInt32) throws
    func addedLatencyMs(aggregate: AudioObjectID) -> Double
    func isProcessRunning(bundleID: String) -> Bool
}
