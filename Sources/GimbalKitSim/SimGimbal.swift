import GimbalKit

public actor SimGimbal: GimbalDevice {
    public nonisolated let capabilities: Capabilities
    public private(set) var pose: Pose
    public private(set) var commands: [MoveCommand] = []
    private var velocity = Pose()
    private var pendingError: (any Error)?

    public init(
        capabilities: Capabilities = [.speedControl, .absoluteControl, .poseFeedback, .battery],
        pose: Pose = Pose()
    ) {
        self.capabilities = capabilities
        self.pose = pose
    }

    public func send(_ command: MoveCommand) async throws {
        if let error = pendingError {
            pendingError = nil
            throw error
        }
        commands.append(command)
        switch command {
        case let .speed(yaw, pitch, roll):
            velocity = Pose(yaw: yaw, pitch: pitch, roll: roll)
        case let .absolute(target, _):
            pose = target
            velocity = Pose()
        case .stop:
            velocity = Pose()
        }
    }

    public func currentPose() -> Pose? {
        capabilities.contains(.poseFeedback) ? pose : nil
    }

    /// Avanza el tiempo simulado: integra la velocidad actual sobre la pose.
    public func advance(seconds: Double) {
        pose.yaw += velocity.yaw * seconds
        pose.pitch += velocity.pitch * seconds
        pose.roll += velocity.roll * seconds
    }

    public func failNextSend(with error: any Error) {
        pendingError = error
    }
}
