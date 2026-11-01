/// Maps fader travel (0 = bottom, 1 = top) to gain. 0…1 gain takes the lower two thirds of
/// the travel (100 % detent at 2/3 height); 1…ceiling takes the top third.
public enum FaderMath {
    static let detent = 2.0 / 3
    /// Gain within this distance of 1.0 snaps to 1.0 while dragging.
    static let snapRange: Float = 0.03
    /// Absolute gain limit (200 %).
    static let maxGain: Float = 2

    public static func value(forPosition p: Double, ceiling: Float) -> Float {
        let p = min(max(p, 0), 1)
        if p <= detent { return Float(p / detent) }
        let boost = max(ceiling, 1) - 1
        return 1 + Float((p - detent) / (1 - detent)) * boost
    }

    public static func position(forValue v: Float, ceiling: Float) -> Double {
        let ceiling = max(ceiling, 1)
        let v = min(max(v, 0), ceiling)
        if v <= 1 { return Double(v) * detent }
        return detent + Double((v - 1) / (ceiling - 1)) * (1 - detent)
    }

    public static func snapped(_ v: Float) -> Float {
        abs(v - 1) <= snapRange ? 1 : v
    }

    /// One scroll tick: ±0.01 with Option held, else ±0.05; clamped to 0…200 %.
    public static func fineStep(_ v: Float, deltaY: Double, option: Bool) -> Float {
        guard deltaY != 0 else { return v }
        let step: Float = option ? 0.01 : 0.05
        return min(max(v + (deltaY > 0 ? step : -step), 0), maxGain)
    }
}
