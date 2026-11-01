import AppKit

/// Scroll-wheel adjustment over a strip: vertical scrolling over the hovered strip moves its
/// fader (fine with Option held); horizontal scrolling still pans the strip row.
@MainActor
final class StripScroll {
    typealias Handler = (_ deltaY: Double, _ option: Bool) -> Void

    private var hovered: (id: String, handler: Handler)?
    private var monitor: Any?
    /// Trackpad points accumulated toward the next tick.
    private var pending: Double = 0
    private static let pointsPerTick: Double = 8

    func hover(_ id: String, _ inside: Bool, handler: @escaping Handler) {
        if inside {
            hovered = (id, handler)
        } else if hovered?.id == id {
            hovered = nil
        }
        pending = 0
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let (dx, dy) = (event.scrollingDeltaX, event.scrollingDeltaY)
            let precise = event.hasPreciseScrollingDeltas
            let option = event.modifierFlags.contains(.option)
            let consumed = MainActor.assumeIsolated {
                self?.consume(deltaX: dx, deltaY: dy, precise: precise, option: option) ?? false
            }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hovered = nil
    }

    /// True when the event adjusted a fader and must not reach the scroll view.
    private func consume(deltaX: Double, deltaY: Double, precise: Bool, option: Bool) -> Bool {
        guard let hovered, abs(deltaY) > abs(deltaX) else { return false }
        if !precise {
            hovered.handler(deltaY, option)
            return true
        }
        pending += deltaY
        while abs(pending) >= Self.pointsPerTick {
            let tick = pending > 0 ? Self.pointsPerTick : -Self.pointsPerTick
            hovered.handler(tick, option)
            pending -= tick
        }
        return true
    }
}
