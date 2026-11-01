import SoundUCore
import SwiftUI

/// The menu-bar panel: a small mixing desk with the master strip pinned left and one channel
/// strip per app scrolling horizontally.
struct PanelView: View {
    let controller: SoundUController
    @State private var scroll = StripScroll()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
            // Placeholder until Call Guard gets its own pill and menu.
            Label("Call Guard", systemImage: "shield")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            Menu {
                SettingsLink { Text("Settings…") }
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
