import Foundation
import GimbalKit

/// Retardo 0,7 s, muestreo 0,7 s, ganancia física 1,25 y frenado conservador 0,20 s.
public actor LaggedPoseDevice: PoseFeedbackDevice {
    public nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    private let sim: SimGimbal
    private let clock: ManualClock
    private var sample: PoseSample
    private var captured: Pose
    private var elapsed = 0.0
    private var immobile = false
    private var physicalVelocity = Pose()
    private var brakingRemaining = 0.0
    public private(set) var frozen = false
    public private(set) var truePoses: [Pose] = []
    public private(set) var sent: [(Date, MoveCommand)] = []
    public init(clock: ManualClock, pose: Pose = Pose()) {
        self.clock = clock; sim = SimGimbal(capabilities: [.speedControl, .poseFeedback], pose: pose)
        captured = pose; sample = PoseSample(pose: pose, receivedAt: clock.now(), sequence: 0)
    }
    public func setFrozen(_ value: Bool) { frozen = value }
    public func setImmobile(_ value: Bool) { immobile = value }
    public func currentPose() -> Pose? { sample.pose }
    public func poseSample() -> PoseSample? { sample }
    public func send(_ command: MoveCommand) async throws {
        sent.append((clock.now(), command))
        switch command {
        case let .speed(y, p, r):
            brakingRemaining = 0
            physicalVelocity = Pose(yaw: y * 1.25, pitch: p * 1.25, roll: r * 1.25)
            try await sim.send(.speed(yaw: physicalVelocity.yaw, pitch: physicalVelocity.pitch, roll: physicalVelocity.roll))
        case .stop:
            if physicalVelocity != Pose() { brakingRemaining = 0.2 }
            else { try await sim.send(.stop) }
        case .absolute: throw SafetyViolation.unsupported(.absoluteControl)
        }
    }
    public func advance(_ seconds: Double) async {
        var remaining = seconds
        while remaining > 1e-9 {
            let step = min(0.1, remaining, brakingRemaining > 1e-9 ? brakingRemaining : remaining)
            clock.advance(step)
            if !immobile { await sim.advance(seconds: step) }
            let pose = await sim.pose
            truePoses.append(pose)
            elapsed += step
            if elapsed >= 0.7 - 1e-9 {
                elapsed -= 0.7
                if !frozen {
                    sample = PoseSample(pose: captured, receivedAt: clock.now(), sequence: sample.sequence &+ 1)
                    captured = pose
                }
            }
            if brakingRemaining > 0 {
                brakingRemaining -= step
                if brakingRemaining <= 1e-9 {
                    brakingRemaining = 0; physicalVelocity = Pose(); try? await sim.send(.stop)
                }
            }
            remaining -= step
        }
    }
}
