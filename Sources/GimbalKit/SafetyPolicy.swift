public struct SafetyPolicy: Sendable, Equatable {
    public var maxSpeed: Double
    public var maxLeaseSeconds: Double
    public var deadmanSeconds: Double
    public var zones: [Zone]

    public init(maxSpeed: Double, maxLeaseSeconds: Double, deadmanSeconds: Double, zones: [Zone]) {
        self.maxSpeed = maxSpeed
        self.maxLeaseSeconds = maxLeaseSeconds
        self.deadmanSeconds = deadmanSeconds
        self.zones = zones
    }

    public static let `default` = SafetyPolicy(maxSpeed: 60, maxLeaseSeconds: 30, deadmanSeconds: 0.5, zones: [])

    public func zone(named name: String) -> Zone? {
        zones.first { $0.name == name }
    }

    public func forbiddenZone(containing pose: Pose) -> Zone? {
        zones.first { $0.forbidden && $0.contains(pose) }
    }
}

public enum SafetyViolation: Error, Equatable {
    case speedTooHigh(limit: Double, requested: Double)
    case noLease
    case leaseExpired
    case unknownZone(String)
    case forbiddenZone(String)
    case outsideZone(String)
    case leaseTooLong(max: Double)
    case invalidDuration
    case invalidValue
    case busy(holder: ControlSource)
    case unsupported(Capabilities)
    case poseUnavailable
}
