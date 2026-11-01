import SoundUCore
import SwiftUI

/// Vertical peak meter. Only this view reads `controller.levels`, so 30 Hz meter updates do
/// not redraw whole strips. Peaks are shown on a −60…0 dBFS scale.
struct MeterView: View {
    let controller: SoundUController
    let appID: String

    private static let floorDB: Float = -60

    private var fraction: CGFloat {
        let peak = controller.levels[appID] ?? 0
        guard peak > 0 else { return 0 }
        let db = 20 * log10(min(peak, 1))
        return CGFloat(max(0, (db - Self.floorDB) / -Self.floorDB))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(.quaternary)
                LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom, endPoint: .top)
                    .frame(height: geo.size.height)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: geo.size.height * fraction)
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(width: 5)
        .accessibilityHidden(true)
    }
}
