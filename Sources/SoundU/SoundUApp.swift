// SoundU entry point. `SoundU --selftest` runs the engine hardware self-test and
// `SoundU --headless` the controller debug command; anything else starts the menu-bar app.
import AppKit
import SoundUCore
import SwiftUI

@main
enum Entry {
    static func main() async {
        if CommandLine.arguments.contains("--selftest") {
            exit(await SelfTest.run())
        }
        if CommandLine.arguments.contains("--headless") {
            exit(await Headless.run(arguments: CommandLine.arguments))
        }
        await MainActor.run { SoundUApp.main() }
    }
}

struct SoundUApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Template glyph arrives with the icon task; SF Symbol until then.
        MenuBarExtra("SoundU", systemImage: "slider.vertical.3") {
            PanelView(controller: delegate.controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: delegate.controller)
        }
    }
}

/// Owns the one controller: starts it at launch (after the first-run sheet on first launch),
/// saves settings when the app quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SoundUController()
    private let firstRun = FirstRunWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if controller.global.firstRunDone {
            controller.start()
            return
        }
        firstRun.show { [controller] in
            controller.start()
            controller.markFirstRunDone()
        }
    }

    /// Saves and exits without stopping IO: the process exit removes SoundU's taps and aggregates.
    func applicationWillTerminate(_ notification: Notification) {
        controller.prepareForTermination()
    }
}
