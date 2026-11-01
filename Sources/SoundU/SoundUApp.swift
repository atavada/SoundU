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
        MenuBarExtra {
            PanelView(controller: delegate.controller)
        } label: {
            MenuBarLabel(controller: delegate.controller)
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

/// Menu-bar glyph; shows a small dot while Call Guard protects a call.
private struct MenuBarLabel: View {
    let controller: SoundUController

    var body: some View {
        if case .protecting(let app) = controller.callGuard {
            Image(nsImage: Self.glyph(dot: true))
                .accessibilityLabel("SoundU, protecting call in \(app)")
        } else {
            Image(nsImage: Self.glyph(dot: false))
                .accessibilityLabel("SoundU")
        }
    }

    /// SoundU's 18 pt template glyph from the bundle; the SF Symbol when it is missing (e.g. when
    /// run unbundled from `swift run`).
    private static let base: NSImage = {
        if let url = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "SoundU")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
    }()

    /// The base glyph, plus a dot in its top-right corner when `dot`; a template image so the
    /// menu bar tints it.
    static func glyph(dot: Bool) -> NSImage {
        guard dot else { return base }
        let diameter: CGFloat = 5
        let size = NSSize(width: base.size.width + diameter / 2, height: base.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: base.size))
            NSBezierPath(ovalIn: NSRect(x: size.width - diameter, y: size.height - diameter,
                                        width: diameter, height: diameter)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
