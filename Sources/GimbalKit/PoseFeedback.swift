import Foundation

public struct PoseSample: Sendable, Equatable {
    public let pose: Pose
    public let receivedAt: Date
    public let sequence: UInt64

    public init(pose: Pose, receivedAt: Date, sequence: UInt64) {
        self.pose = pose
        self.receivedAt = receivedAt
        self.sequence = sequence
    }
}

public protocol PoseFeedbackDevice: GimbalDevice {
    func poseSample() async -> PoseSample?
}

public struct RuntimeClock: Sendable {
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (Double) async throws -> Void

    public init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Double) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    public static var live: RuntimeClock {
        let base = Date()
        let clock = ContinuousClock()
        let start = clock.now
        return RuntimeClock(
            now: {
                let elapsed = start.duration(to: clock.now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                return base.addingTimeInterval(seconds)
            },
            sleep: { try await Task.sleep(for: .seconds($0)) }
        )
    }
}
