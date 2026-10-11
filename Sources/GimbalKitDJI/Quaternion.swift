public struct Quaternion: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    /// Normalizado, o nil si no es finito o su norma no es creíble (fuera de 0,9...1,1 antes de normalizar).
    public var normalized: Quaternion? {
        let n = (x * x + y * y + z * z + w * w).squareRoot()
        guard n.isFinite, n > 0.9, n < 1.1 else { return nil }
        return Quaternion(x: x / n, y: y / n, z: z / n, w: w / n)
    }

    public var conjugate: Quaternion { Quaternion(x: -x, y: -y, z: -z, w: w) }

    public static func * (a: Quaternion, b: Quaternion) -> Quaternion {
        Quaternion(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }
}
