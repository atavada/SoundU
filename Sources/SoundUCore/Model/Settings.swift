// Persisted user settings: per-app volume/mute/output and global preferences.

/// One app's saved mixer state, keyed by bundle ID in `SettingsSnapshot.apps`.
public struct AppSetting: Codable, Equatable, Sendable {
    /// Gain 0...2 (0–200 %); clamped to the boost ceiling by `SettingsSnapshot.setting(for:)`.
    public var volume: Float
    public var muted: Bool
    /// Preferred output device UID; kept even if the device is currently absent.
    public var outputDeviceUID: String?

    public init(volume: Float, muted: Bool, outputDeviceUID: String?) {
        self.volume = volume
        self.muted = muted
        self.outputDeviceUID = outputDeviceUID
    }

    public static let `default` = AppSetting(volume: 1, muted: false, outputDeviceUID: nil)
}

public struct GlobalSettings: Codable, Equatable, Sendable {
    public var callGuardEnabled = true
    public var callApps: [String] = [
        "net.whatsapp.WhatsApp",
        "com.apple.FaceTime",
        "com.apple.avconferenced",
        "com.apple.mobilephone",
    ]
    /// Maximum per-app gain, 1.0–2.0.
    public var boostCeiling: Float = 2.0
    public var launchAtLogin = false
    public var firstRunDone = false

    public init() {}
}

public struct SettingsSnapshot: Codable, Equatable, Sendable {
    public var apps: [String: AppSetting]
    public var global: GlobalSettings

    public init(apps: [String: AppSetting] = [:], global: GlobalSettings = GlobalSettings()) {
        self.apps = apps
        self.global = global
    }

    /// The saved setting for `bundleID` (or `.default`), with volume clamped to `0...boostCeiling`.
    public func setting(for bundleID: String) -> AppSetting {
        var setting = apps[bundleID] ?? .default
        setting.volume = min(max(setting.volume, 0), global.boostCeiling)
        return setting
    }
}
