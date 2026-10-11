/// Mensajes de telemetría de la serie OM que sabemos interpretar (medidos en hardware, ver docs/research).
public enum OMTelemetry: Sendable, Equatable {
    case attitude(Quaternion)
    case battery(percent: Int, charging: Bool)

    public static func decode(_ frame: DUMLFrame) -> OMTelemetry? {
        switch (frame.commandSet, frame.command) {
        case (0x04, 0x05):
            // Cuaternión (x, y, z, w) como 4 × Float32 LE en carga[24..<40].
            guard frame.payload.count >= 40 else { return nil }
            let f = (0..<4).map { i -> Double in
                let o = 24 + i * 4
                let raw = UInt32(frame.payload[o]) | UInt32(frame.payload[o + 1]) << 8
                    | UInt32(frame.payload[o + 2]) << 16 | UInt32(frame.payload[o + 3]) << 24
                return Double(Float(bitPattern: raw))
            }
            guard let q = Quaternion(x: f[0], y: f[1], z: f[2], w: f[3]).normalized else { return nil }
            return .attitude(q)
        case (0x05, 0x06):
            guard let first = frame.payload.first, first <= 100, let last = frame.payload.last else { return nil }
            return .battery(percent: Int(first), charging: last == 1)
        default:
            return nil
        }
    }
}
