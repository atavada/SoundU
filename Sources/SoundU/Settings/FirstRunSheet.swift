import AppKit
import SoundUCore
import SwiftUI

/// First-run explanation. SoundU is a menu-bar app with no main window, so the sheet lives in a
/// small window of its own; Continue starts the controller, which creates the first tap and so
/// triggers the Audio Capture prompt.
struct FirstRunSheet: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text("Welcome to SoundU").font(.title2.weight(.semibold))
            }
            Text("SoundU sets the volume of each app separately, from the menu bar.")
            Text("To do that it needs **Audio Capture** permission: macOS routes each app's sound through SoundU so it can be turned up, down or muted. SoundU never records or stores audio.")
            Text("macOS asks for permission the first time an app plays sound. If you choose Don't Allow, apps keep playing normally and you can allow it later in System Settings › Privacy & Security › Audio Capture.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 420)
    }
}

/// Owns the first-run window while it is shown.
@MainActor
final class FirstRunWindow {
    private var window: NSWindow?

    func show(onContinue: @escaping () -> Void) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "SoundU"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FirstRunSheet { [weak self] in
            self?.close()
            onContinue()
        })
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
        window = nil
    }
}
