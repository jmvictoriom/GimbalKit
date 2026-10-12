import Foundation
import GimbalKit

public enum LookOutcome: Sendable, Equatable {
    case arrived(String)
    case alreadyInside(String)
    case failed(String, String)
    case idle

    public var zone: String? {
        switch self {
        case let .arrived(zone), let .alreadyInside(zone), let .failed(zone, _): zone
        case .idle: nil
        }
    }

    /// Distancia euclídea en grados: cambio de pose < 0,5° y centro yaw/pitch < 2°.
    public static func success(zone: String, bounds: ZoneRecord?, before: Pose?, after: Pose) -> Self {
        guard let before, before.isFinite, after.isFinite,
              let bounds, bounds.name == zone,
              [bounds.yawLower, bounds.yawUpper, bounds.pitchLower, bounds.pitchUpper].allSatisfy(\.isFinite),
              bounds.yawLower < bounds.yawUpper, bounds.pitchLower < bounds.pitchUpper else {
            return .arrived(zone)
        }
        let change = hypot(hypot(after.yaw - before.yaw, after.pitch - before.pitch), after.roll - before.roll)
        let centerYaw = bounds.yawLower / 2 + bounds.yawUpper / 2
        let centerPitch = bounds.pitchLower / 2 + bounds.pitchUpper / 2
        let distance = hypot(after.yaw - centerYaw, after.pitch - centerPitch)
        return change < 0.5 && distance < 2 ? .alreadyInside(zone) : .arrived(zone)
    }
}
