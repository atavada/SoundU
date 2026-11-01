import AppKit
import SoundUCore
import SwiftUI

/// Opens the Audio Capture pane of System Settings › Privacy & Security.
@MainActor
func openAudioCaptureSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
}

/// Shown at the top of the panel while Audio Capture permission is pending: SoundU leaves
/// every app untouched until it is granted.
struct PermissionBanner: View {
    let controller: SoundUController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio Capture permission needed").font(.callout.weight(.semibold))
                Text("Apps play normally; SoundU can't adjust them until you allow it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Open System Settings", action: openAudioCaptureSettings)
                .controlSize(.small)
            Button("Try Again") { controller.retryPermission() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.12))
    }
}
