import GimbalKit

/// Coordenadas normalizadas: (0, 0) es la esquina superior izquierda.
/// La vista decide el tamaño en puntos; esta proyección nunca ordena movimiento.
public enum ZoneMapProjection {
    public struct Point: Sendable, Equatable {
        public let x: Double
        public let y: Double
    }

    public struct Rect: Sendable, Equatable {
        public let origin: Point
        public let width: Double
        public let height: Double
    }

    public static func point(yaw: Double, pitch: Double) -> Point? {
        guard yaw.isFinite, pitch.isFinite else { return nil }
        return Point(x: (min(90, max(-90, yaw)) + 90) / 180,
                     y: (45 - min(45, max(-45, pitch))) / 90)
    }

    public static func point(for pose: Pose?) -> Point? {
        guard let pose, pose.isFinite else { return nil }
        return point(yaw: pose.yaw, pitch: pose.pitch)
    }

    public static func rect(for zone: ZoneRecord) -> Rect? {
        guard zone.yawLower < zone.yawUpper, zone.pitchLower < zone.pitchUpper,
              let topLeft = point(yaw: zone.yawLower, pitch: zone.pitchUpper),
              let bottomRight = point(yaw: zone.yawUpper, pitch: zone.pitchLower) else { return nil }
        return Rect(origin: topLeft, width: bottomRight.x - topLeft.x,
                    height: bottomRight.y - topLeft.y)
    }
}
