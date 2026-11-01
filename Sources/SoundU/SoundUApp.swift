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
            Text("Settings are coming soon.")
                .padding(40)
        }
    }
}

/// Owns the one controller: starts it at launch, stops every graph before the app quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SoundUController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [controller] _ in
            MainActor.assumeIsolated { controller.shutdown() }
        }
    }
}
