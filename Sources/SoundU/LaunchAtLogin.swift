// Registers SoundU as a login item through SMAppService.
import os
import ServiceManagement

enum LaunchAtLogin {
    private static let log = Logger(subsystem: "com.example.SoundU", category: "LaunchAtLogin")

    /// Whether the system currently has SoundU registered to open at login.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or unregisters the app; returns the resulting state (unchanged on failure,
    /// e.g. when running outside an app bundle).
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Launch at login \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        return isEnabled
    }
}
