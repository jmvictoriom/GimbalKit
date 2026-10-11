/// 10 unidades crudas por °/s (≈ 0,1 °/s por unidad; medido en la SE entre 100 y 400 unidades).
public enum OMUnits {
    public static let unitsPerDegreePerSecond = 10.0
    public static let maxRaw: Int16 = 1000

    public static func raw(forDegreesPerSecond value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let scaled = (value * unitsPerDegreePerSecond).rounded()
        return Int16(max(-Double(maxRaw), min(Double(maxRaw), scaled)))
    }

    public static func degreesPerSecond(forRaw raw: Int16) -> Double {
        Double(raw) / unitsPerDegreePerSecond
    }
}
