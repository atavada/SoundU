import CoreAudio
import Darwin

/// Thin typed accessors over `AudioObject{Get,Set}PropertyData`, plus private symbols
/// resolved at run time.
enum HAL {
    /// `'nodk'`: per-device opt-out from the Call Guard ducking applied during calls.
    static let noDuckSelector: AudioObjectPropertySelector = 0x6e6f646b

    typealias AudioDeviceDuckFn = @convention(c) (AudioObjectID, Float32, UnsafePointer<AudioTimeStamp>?, Float32) -> OSStatus

    /// Private `AudioDeviceDuck` from CoreAudio (fallback for the 'nodk' exemption).
    static func audioDeviceDuck() -> AudioDeviceDuckFn? {
        guard let sym = dlsym(rtldDefault, "AudioDeviceDuck") else { return nil }
        return unsafeBitCast(sym, to: AudioDeviceDuckFn.self)
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func uint32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func int32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var addr = address(selector)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func double(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Double? {
        var addr = address(selector, scope)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr,
              let ref = value else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func objectIDs(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// Total channel count of the device's streams in `scope`.
    static func channelCount(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    @discardableResult
    static func setUInt32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          _ value: UInt32) -> OSStatus {
        var addr = address(selector, scope)
        var v = value
        return AudioObjectSetPropertyData(obj, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    static func isSettable(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope)
        guard AudioObjectHasProperty(obj, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(obj, &addr, &settable) == noErr && settable.boolValue
    }

    // MARK: - Process info

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    /// The pid macOS holds responsible for `pid` (e.g. the app that owns an XPC helper).
    static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let sym = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
        let r = unsafeBitCast(sym, to: ResponsibleFn.self)(pid)
        return r > 0 ? r : nil
    }

    static func executablePath(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return "" }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `RTLD_DEFAULT` (`(void *)-2`), which Swift does not import.
    private static var rtldDefault: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: -2) }
}
