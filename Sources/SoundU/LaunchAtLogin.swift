// Registers SoundU as a login item through SMAppService. `mainApp` only works for a bundle
// installed in /Applications (`scripts/build-app.sh --release --install`).
import AppKit
import os
import ServiceManagement

enum LaunchAtLogin {
    private static let log = Logger(subsystem: "com.example.SoundU", category: "LaunchAtLogin")

    /// Whether SoundU is registered to open at login. `.requiresApproval` counts as on: the
    /// item is registered and only waits for the user to allow it in System Settings.
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// True while the login item is registered but not yet allowed by the user.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

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

    /// Opens System Settings › General › Login Items.
    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
