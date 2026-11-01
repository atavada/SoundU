import SoundUCore
import SwiftUI

/// Vertical fader. With a boost ceiling, 0…100 % fills the lower two thirds (line and detent at
/// 100 %) and the tinted top third runs to the ceiling; without one it is linear 0…100 %.
/// Dragging is relative to the knob; double-click resets to 100 %.
struct Fader: View {
    var value: Float
    var boostCeiling: Float?
    var onChange: (Float) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var dragStart: Double?

    private static let knobHeight: CGFloat = 12
    private static let width: CGFloat = 22

    private func position(of v: Float) -> Double {
        boostCeiling.map { FaderMath.position(forValue: v, ceiling: $0) } ?? Double(min(max(v, 0), 1))
    }

    private func gain(at p: Double) -> Float {
        guard let ceiling = boostCeiling else { return Float(min(max(p, 0), 1)) }
        return FaderMath.snapped(FaderMath.value(forPosition: p, ceiling: ceiling))
    }

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.height - Self.knobHeight, 1)
            let y = { (p: Double) in Self.knobHeight / 2 + travel * (1 - p) }
            ZStack(alignment: .top) {
                if let ceiling = boostCeiling, ceiling > 1 {
                    Rectangle()
                        .fill(Color.orange.opacity(0.18))
                        .frame(width: Self.width - 6, height: y(position(of: 1)) - y(1))
                        .offset(y: y(1))
                }
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 4, height: travel)
                    .offset(y: Self.knobHeight / 2)
                Capsule()
                    .fill(Color.accentColor.opacity(isEnabled ? 0.8 : 0.3))
                    .frame(width: 4, height: travel * position(of: value))
                    .offset(y: y(position(of: value)))
                if boostCeiling != nil {
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: Self.width, height: 1)
                        .offset(y: y(position(of: 1)))
                }
                RoundedRectangle(cornerRadius: 3)
                    .fill(.background)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.6)))
                    .shadow(radius: 1, y: 0.5)
                    .frame(width: Self.width, height: Self.knobHeight)
                    .offset(y: y(position(of: value)) - Self.knobHeight / 2)
                    .opacity(isEnabled ? 1 : 0.4)
            }
            .frame(width: Self.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = dragStart ?? position(of: value)
                        if dragStart == nil { dragStart = start }
                        let next = gain(at: start - drag.translation.height / travel)
                        if next != value { onChange(next) }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(1) })
        }
        .frame(width: Self.width)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step: Float = direction == .increment ? 0.05 : -0.05
            onChange(min(max(value + step, 0), boostCeiling ?? 1))
        }
    }
}
