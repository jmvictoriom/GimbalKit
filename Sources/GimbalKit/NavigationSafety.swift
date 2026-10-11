import Foundation

public struct NavigationLimits: Sendable {
    public let maxSpeed = 6.0
    public let gain = 1.0
    public let deadband = 2.0
    public let pulseSeconds = 0.30
    public let brakingSeconds = 0.20
    public let physicalGain = 1.25
    public let margin = 0.5
    public let settleSeconds = 0.90
    public let staleSeconds = 1.5
    public let timeoutSeconds = 25.0
    public init() {}
}
public enum NavigationError: Error, Sendable, Equatable {
    case stalePose, timeout, unsafePath, interrupted, busy, referenceRequired
}
public struct NavigationContext: Sendable {
    public let zone: Zone
    public let forbidden: [Zone]
    public let sample: PoseSample
}
public enum NavigationSafety {
    public static func check(pose p: Pose, velocity v: Pose, zone: Zone,
                             forbidden: [Zone], limits l: NavigationLimits) throws {
        guard p.isFinite, v.isFinite, v.roll == 0,
              max(abs(v.yaw), abs(v.pitch)) <= l.maxSpeed else { throw SafetyViolation.invalidValue }
        let t = (l.pulseSeconds + l.brakingSeconds) * l.physicalGain
        let q = Pose(yaw: p.yaw + v.yaw * t, pitch: p.pitch + v.pitch * t)
        let y = (min(p.yaw, q.yaw) - l.margin)...(max(p.yaw, q.yaw) + l.margin)
        let x = (min(p.pitch, q.pitch) - l.margin)...(max(p.pitch, q.pitch) + l.margin)
        guard zone.yaw.lowerBound <= y.lowerBound, zone.yaw.upperBound >= y.upperBound,
              zone.pitch.lowerBound <= x.lowerBound, zone.pitch.upperBound >= x.upperBound,
              !forbidden.contains(where: { $0.yaw.overlaps(y) && $0.pitch.overlaps(x) }) else {
            throw NavigationError.unsafePath
        }
    }
}
