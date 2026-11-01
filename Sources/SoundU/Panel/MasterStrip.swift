import CoreAudio
import Observation
import SoundUCore
import SwiftUI

/// The pinned master strip: the default output device's volume and mute, and a picker that
/// changes the system default output device.
struct MasterStrip: View {
    let controller: SoundUController
    let scroll: StripScroll
    @State private var model = MasterModel()

    private var defaultDevice: OutputDevice? {
        controller.devices.first { $0.uid == controller.defaultDeviceUID }
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 20))
                .frame(width: 28, height: 28)
            Text("Master").font(.caption.weight(.semibold))
            Fader(value: model.volume, boostCeiling: nil) { model.setVolume($0) }
                .disabled(!model.settable)
                .frame(maxHeight: .infinity)
            Text(model.settable ? "\(Int((model.volume * 100).rounded()))%" : "Fixed")
                .font(.caption.monospacedDigit())
            Button {
                model.toggleMute()
            } label: {
                Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(model.muted ? Color.red : Color.primary)
                    .frame(width: 24, height: 18)
            }
            .buttonStyle(.borderless)
            .help(model.muted ? "Unmute" : "Mute")
            devicePicker
        }
        .padding(.vertical, 10)
        .frame(width: 86)
        .onChange(of: defaultDevice?.id, initial: true) { _, id in model.track(id) }
        .onHover { inside in
            scroll.hover("master", inside && model.settable) { deltaY, option in
                model.setVolume(FaderMath.fineStep(model.volume, deltaY: deltaY, option: option))
            }
        }
    }

    private var devicePicker: some View {
        Menu {
            ForEach(controller.devices, id: \.uid) { device in
                Button {
                    MasterVolume.setDefaultOutputDevice(device.id)
                } label: {
                    if device.uid == controller.defaultDeviceUID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            Text(defaultDevice?.name ?? "No output").font(.caption2).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .frame(maxWidth: 78)
        .help(defaultDevice?.name ?? "No output device")
    }
}

/// Live volume/mute of the tracked device, refreshed by HAL listeners.
@MainActor
@Observable
final class MasterModel {
    private(set) var volume: Float = 0
    private(set) var muted = false
    private(set) var settable = false
    @ObservationIgnored private var device: AudioObjectID?
    @ObservationIgnored private var listener: AnyObject?

    func track(_ device: AudioObjectID?) {
        guard device != self.device else { return }
        self.device = device
        listener = device.map { id in
            MasterVolume.observe(id) { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }

    func setVolume(_ v: Float) {
        guard let device, MasterVolume.setVolume(v, of: device) else { return }
        volume = min(max(v, 0), 1)
    }

    func toggleMute() {
        guard let device, MasterVolume.setMuted(!muted, of: device) else { return }
        muted.toggle()
    }

    private func refresh() {
        guard let device else {
            (volume, muted, settable) = (0, false, false)
            return
        }
        volume = MasterVolume.volume(of: device) ?? 1
        muted = MasterVolume.isMuted(device)
        settable = MasterVolume.canSetVolume(of: device)
    }
}
