import SoundUCore
import SwiftUI

/// One app's strip: icon, name, fader with meter, percentage, mute and output chip.
struct ChannelStrip: View {
    let strip: AppStrip
    let controller: SoundUController
    let scroll: StripScroll

    private var locked: Bool {
        if case .locked = strip.state { return true }
        return false
    }

    private var metered: Bool { strip.state == .routed || strip.state == .lingering }

    var body: some View {
        VStack(spacing: 6) {
            icon
            Text(strip.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(strip.name)
            HStack(spacing: 4) {
                Fader(value: strip.volume, boostCeiling: controller.boostCeiling) {
                    controller.setVolume(strip.id, $0)
                }
                .disabled(locked)
                if metered {
                    MeterView(controller: controller, appID: strip.id)
                        .padding(.vertical, 6) // match the fader track (knob height / 2)
                }
            }
            .frame(maxHeight: .infinity)
            status
            controls
        }
        .padding(.vertical, 10)
        .frame(width: 78)
        .opacity(strip.state == .lingering ? 0.5 : 1)
        .onHover { inside in
            scroll.hover(strip.id, inside && !locked) { deltaY, option in
                let current = controller.apps.first { $0.id == strip.id }?.volume ?? strip.volume
                controller.setVolume(strip.id, FaderMath.fineStep(current, deltaY: deltaY, option: option))
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = strip.icon {
            Image(nsImage: image).resizable().frame(width: 28, height: 28)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 22)).frame(width: 28, height: 28)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch strip.state {
        case .routed, .lingering:
            Text("\(Int((strip.volume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
        case .locked:
            Text("In call").font(.caption).foregroundStyle(.secondary)
        case .notRouted(let reason):
            Text(reason == .permissionPending ? "Needs access" : "Not routed")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(reason == .permissionPending
                      ? "Waiting for Audio Capture permission; the app plays normally."
                      : "SoundU leaves this app alone.")
        case .error(let message):
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.yellow)
                .help(message)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if locked {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .frame(height: 22)
                .help("SoundU never touches call audio.")
        } else {
            Button {
                controller.toggleMute(strip.id)
            } label: {
                Image(systemName: strip.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(strip.muted ? Color.red : Color.primary)
                    .frame(width: 24, height: 18)
            }
            .buttonStyle(.borderless)
            .help(strip.muted ? "Unmute" : "Mute")
            OutputChip(strip: strip, controller: controller)
        }
    }
}

/// The strip's output-device menu: "Default" follows the system default output device.
private struct OutputChip: View {
    let strip: AppStrip
    let controller: SoundUController

    private var title: String {
        guard let uid = strip.outputDeviceUID else { return "Default" }
        return controller.devices.first { $0.uid == uid }?.name ?? "Offline"
    }

    var body: some View {
        Menu {
            Button("Default") { controller.setOutput(strip.id, deviceUID: nil) }
            Divider()
            ForEach(controller.devices, id: \.uid) { device in
                Button(device.name) { controller.setOutput(strip.id, deviceUID: device.uid) }
            }
        } label: {
            Text(title).font(.caption2).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .frame(maxWidth: 70)
        .fixedSize(horizontal: false, vertical: true)
        .help(title)
    }
}
