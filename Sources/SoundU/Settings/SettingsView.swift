import SoundUCore
import SwiftUI

/// The Settings window: General, Call Guard, Permissions and About tabs.
struct SettingsView: View {
    let controller: SoundUController

    var body: some View {
        TabView {
            GeneralTab(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            CallGuardTab(controller: controller)
                .tabItem { Label("Call Guard", systemImage: "shield") }
            PermissionsTab(controller: controller)
                .tabItem { Label("Permissions", systemImage: "lock") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 320)
    }
}

private struct GeneralTab: View {
    let controller: SoundUController
    @State private var needsApproval = false

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { controller.global.launchAtLogin },
                set: {
                    controller.setLaunchAtLogin(LaunchAtLogin.set($0))
                    needsApproval = LaunchAtLogin.needsApproval
                }
            ))
            if needsApproval {
                HStack {
                    Label("Needs approval in System Settings › General › Login Items",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                }
            }
            LabeledContent("Boost ceiling") {
                HStack {
                    Slider(value: Binding(
                        get: { Double(controller.global.boostCeiling) },
                        set: { controller.setBoostCeiling(Float($0)) }
                    ), in: 1...2, step: 0.05)
                    Text("\(Int((controller.global.boostCeiling * 100).rounded())) %")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            Text("The highest level an app's fader can reach. Louder apps play at the ceiling and get their level back when you raise it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        // The system is the source of truth (the user can remove the login item elsewhere).
        .onAppear {
            let enabled = LaunchAtLogin.isEnabled
            if enabled != controller.global.launchAtLogin { controller.setLaunchAtLogin(enabled) }
            needsApproval = LaunchAtLogin.needsApproval
        }
    }
}

private struct CallGuardTab: View {
    let controller: SoundUController
    @State private var selection: String?
    @State private var newID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Protect calls from being ducked", isOn: Binding(
                get: { controller.global.callGuardEnabled },
                set: { controller.setCallGuardEnabled($0) }
            ))
            Text("Call apps (bundle IDs). SoundU never taps or changes these while they are in a call.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(controller.global.callApps, id: \.self, selection: $selection) { Text($0) }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Button { remove() } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Remove the selected app")
                TextField("Bundle ID, e.g. us.zoom.xos", text: $newID)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(trimmed.isEmpty || controller.global.callApps.contains(trimmed))
                Spacer()
                Button("Reset to Defaults") { controller.resetCallApps() }
            }
        }
        .padding(20)
    }

    private var trimmed: String { newID.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func add() {
        let id = trimmed
        guard !id.isEmpty, !controller.global.callApps.contains(id) else { return }
        controller.setCallApps(controller.global.callApps + [id])
        newID = ""
    }

    private func remove() {
        guard let selection else { return }
        controller.setCallApps(controller.global.callApps.filter { $0 != selection })
        self.selection = nil
    }
}

private struct PermissionsTab: View {
    let controller: SoundUController

    var body: some View {
        Form {
            LabeledContent("Audio Capture") {
                Label(status.text, systemImage: status.symbol)
                    .foregroundStyle(status.color)
            }
            Text("SoundU needs Audio Capture permission to change each app's volume. Without it, apps play normally and are left untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open System Settings", action: openAudioCaptureSettings)
                if controller.permission == .pending {
                    Button("Try Again") { controller.retryPermission() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var status: (text: String, symbol: String, color: Color) {
        switch controller.permission {
        case .granted: ("Allowed", "checkmark.circle.fill", .green)
        case .pending: ("Not allowed", "exclamationmark.triangle.fill", .orange)
        case .unknown: ("Not checked yet (asked when an app plays)", "questionmark.circle", .secondary)
        }
    }
}

private struct AboutTab: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("SoundU").font(.title2.weight(.semibold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("A per-app volume mixer for the menu bar.")
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
