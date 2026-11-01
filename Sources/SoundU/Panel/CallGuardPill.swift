import SoundUCore
import SwiftUI

/// Header pill: Call Guard status, with a menu to turn it on or off and edit the call-app list.
struct CallGuardPill: View {
    let controller: SoundUController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            Toggle("Call Guard", isOn: Binding(
                get: { controller.global.callGuardEnabled },
                set: { controller.setCallGuardEnabled($0) }
            ))
            .disabled(controller.callGuard == .unavailable)
            Section("Call apps") {
                ForEach(controller.global.callApps, id: \.self) { Text($0) }
            }
            Button("Edit Call Apps…") {
                openSettings()
                // SoundU is LSUIElement: without activating, Settings opens behind other apps.
                NSApp.activate()
            }
            Button("Reset to Defaults") { controller.resetCallApps() }
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(tint)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .help(help)
    }

    private var title: String {
        switch controller.callGuard {
        case .on: "Call Guard: On"
        case .off: "Call Guard: Off"
        case .protecting(let app): "Protecting call in \(app)"
        case .unavailable: "Call Guard: Unavailable"
        }
    }

    private var symbol: String {
        switch controller.callGuard {
        case .on: "shield"
        case .off: "shield.slash"
        case .protecting: "shield.fill"
        case .unavailable: "exclamationmark.shield"
        }
    }

    private var tint: Color {
        switch controller.callGuard {
        case .protecting: .green
        case .on: .primary
        case .off, .unavailable: .secondary
        }
    }

    private var help: String {
        switch controller.callGuard {
        case .on, .protecting: "Other apps keep their volume during calls; call audio is never touched."
        case .off: "Calls may lower other apps' volume. Call audio is still never touched."
        case .unavailable: "Unavailable on this macOS: no way to opt SoundU's output out of call ducking."
        }
    }
}
