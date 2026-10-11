import Foundation
import GimbalKit

/// Convierte el cuaternión de la Osmo en una `Pose` en grados relativa a una referencia (la primera orientación recibida).
/// Descomposición YXZ de la rotación relativa: Y = yaw, X = pitch (con el signo invertido, medido en hardware), Z = roll.
public struct OMPoseEstimator: Sendable {
    private var reference: Quaternion?
    public private(set) var pose: Pose?

    public init() {}

    public mutating func zero() {
        reference = nil
        pose = nil
    }

    @discardableResult
    public mutating func update(_ q: Quaternion) -> Pose {
        let ref = reference ?? q
        reference = ref
        let d = q * ref.conjugate
        let r02 = 2 * (d.x * d.z + d.y * d.w)
        let r12 = 2 * (d.y * d.z - d.x * d.w)
        let r22 = 1 - 2 * (d.x * d.x + d.y * d.y)
        let r10 = 2 * (d.x * d.y + d.z * d.w)
        let r11 = 1 - 2 * (d.x * d.x + d.z * d.z)
        let yaw = atan2(r02, r22)
        let thetaX = asin(max(-1, min(1, -r12)))
        let roll = atan2(r10, r11)
        let result = Pose(
            yaw: yaw * 180 / .pi,
            pitch: -thetaX * 180 / .pi,
            roll: roll * 180 / .pi
        )
        pose = result
        return result
    }
}
