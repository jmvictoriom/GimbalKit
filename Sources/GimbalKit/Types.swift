public struct Pose: Sendable, Equatable, Codable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    public var isFinite: Bool { yaw.isFinite && pitch.isFinite && roll.isFinite }
}

public struct Capabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let speedControl = Capabilities(rawValue: 1 << 0)
    public static let absoluteControl = Capabilities(rawValue: 1 << 1)
    public static let poseFeedback = Capabilities(rawValue: 1 << 2)
    public static let joystickInput = Capabilities(rawValue: 1 << 3)
    public static let battery = Capabilities(rawValue: 1 << 4)
}

/// Velocidades en grados por segundo; poses en grados.
public enum MoveCommand: Sendable, Equatable {
    case speed(yaw: Double, pitch: Double, roll: Double)
    case absolute(Pose, seconds: Double)
    case stop
}

public enum ControlSource: Sendable, Hashable {
    case physical
    case app
    case shortcut
    case agent(String)

    /// Las fuentes del propio usuario (mando físico, app) no necesitan lease y expropian el turno.
    public var isPrivileged: Bool {
        switch self {
        case .physical, .app: true
        case .shortcut, .agent: false
        }
    }
}

public struct Zone: Sendable, Equatable, Codable {
    public var name: String
    public var yaw: ClosedRange<Double>
    public var pitch: ClosedRange<Double>
    public var forbidden: Bool

    public init(name: String, yaw: ClosedRange<Double>, pitch: ClosedRange<Double>, forbidden: Bool = false) {
        self.name = name
        self.yaw = yaw
        self.pitch = pitch
        self.forbidden = forbidden
    }

    public func contains(_ pose: Pose) -> Bool {
        pose.isFinite && yaw.contains(pose.yaw) && pitch.contains(pose.pitch)
    }
}

public protocol GimbalDevice: Sendable {
    var capabilities: Capabilities { get }
    func send(_ command: MoveCommand) async throws
    func currentPose() async -> Pose?
}
