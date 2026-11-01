import SoundUCore
import SwiftUI

/// The menu-bar panel: a small mixing desk with the master strip pinned left and one channel
/// strip per app scrolling horizontally.
struct PanelView: View {
    let controller: SoundUController
    @State private var scroll = StripScroll()
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if controller.permission == .pending {
                PermissionBanner(controller: controller)
                Divider()
            }
            HStack(spacing: 0) {
                MasterStrip(controller: controller, scroll: scroll)
                Divider()
                strips
            }
        }
        .frame(width: 460, height: 340)
        .background(.ultraThinMaterial)
        .onAppear { scroll.install() }
        .onDisappear { scroll.remove() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("SoundU").font(.headline)
            Spacer()
            CallGuardPill(controller: controller)
            Menu {
                Button("Settings…") {
                    openSettings()
                    // SoundU is LSUIElement: without activating, Settings opens behind other apps.
                    NSApp.activate()
                }
                Divider()
                Button("Quit SoundU") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// SoundU's own audio (its aggregates) is never a strip.
    private var visibleApps: [AppStrip] {
        controller.apps.filter { $0.state != .notRouted(.soundU) }
    }

    @ViewBuilder
    private var strips: some View {
        if visibleApps.isEmpty {
            Text("Apps playing sound appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(visibleApps) { strip in
                        ChannelStrip(strip: strip, controller: controller, scroll: scroll)
                        Divider()
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }
}
