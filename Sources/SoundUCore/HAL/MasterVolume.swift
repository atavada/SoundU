import AudioToolbox
import CoreAudio
import Foundation

/// The master strip's HAL access: a device's main output volume and mute (what the system
/// volume control shows), and switching the system default output device.
public enum MasterVolume {
    private static let volumeAddress = HAL.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                   kAudioDevicePropertyScopeOutput)
    private static let muteAddress = HAL.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)

    /// Main volume 0...1, or nil when the device has no software volume.
    public static func volume(of device: AudioObjectID) -> Float? {
        var addr = volumeAddress
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    public static func canSetVolume(of device: AudioObjectID) -> Bool {
        HAL.isSettable(device, volumeAddress.mSelector, volumeAddress.mScope)
    }

    @discardableResult
    public static func setVolume(_ volume: Float, of device: AudioObjectID) -> Bool {
        var addr = volumeAddress
        var value = Float32(min(max(volume, 0), 1))
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    public static func isMuted(_ device: AudioObjectID) -> Bool {
        HAL.uint32(device, muteAddress.mSelector, muteAddress.mScope) == 1
    }

    @discardableResult
    public static func setMuted(_ muted: Bool, of device: AudioObjectID) -> Bool {
        HAL.setUInt32(device, muteAddress.mSelector, muteAddress.mScope, muted ? 1 : 0) == noErr
    }

    /// Makes `device` the system default output device.
    @discardableResult
    public static func setDefaultOutputDevice(_ device: AudioObjectID) -> Bool {
        HAL.setUInt32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                      kAudioObjectPropertyScopeGlobal, device) == noErr
    }

    /// Calls `onChange` on the main queue whenever the device's volume or mute changes; listening
    /// stops when the returned object is released.
    public static func observe(_ device: AudioObjectID, _ onChange: @escaping @Sendable () -> Void) -> AnyObject {
        Listener(device: device, addresses: [volumeAddress, muteAddress], onChange)
    }

    private final class Listener {
        private let device: AudioObjectID
        private var registered: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

        init(device: AudioObjectID, addresses: [AudioObjectPropertyAddress], _ onChange: @escaping @Sendable () -> Void) {
            self.device = device
            for address in addresses {
                var addr = address
                let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
                if AudioObjectAddPropertyListenerBlock(device, &addr, .main, block) == noErr {
                    registered.append((address, block))
                }
            }
        }

        deinit {
            for (address, block) in registered {
                var addr = address
                AudioObjectRemovePropertyListenerBlock(device, &addr, .main, block)
            }
        }
    }
}
