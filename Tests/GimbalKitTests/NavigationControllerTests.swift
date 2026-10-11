import Foundation
import Testing
import GimbalKit
import GimbalKitSim

actor OrderedDevice: PoseFeedbackDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    private(set) var commands: [MoveCommand] = []
    private var pending: CheckedContinuation<Void, Never>?
    var waiting: Bool { pending != nil }
    func currentPose() -> Pose? { Pose() }
    func poseSample() -> PoseSample? { PoseSample(pose: Pose(), receivedAt: Date(timeIntervalSince1970: 1_000_000), sequence: 1) }
    func send(_ command: MoveCommand) async throws {
        if case .speed = command { await withCheckedContinuation { pending = $0 } }
        commands.append(command)
    }
    func open() { pending?.resume(); pending = nil }
}

@Test func queuedSpeedCannotFollowConcurrentStop() async throws {
    let dev = OrderedDevice()
    let clock = ManualClock()
    let c = GimbalController(device: dev, policy: makePolicy(), now: { clock.now() })
    let l = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 20)
    let moving = Task { try await c.navigationPulse(Pose(yaw: 2), source: l.source, lease: l) }
    while !(await dev.waiting) { await Task.yield() }
    let stopping = Task { await c.stop(source: .app) }
    while await c.activeLease != nil { await Task.yield() }
    await dev.open()
    _ = try? await moving.value
    await stopping.value
    #expect(await dev.commands == [.speed(yaw: 2, pitch: 0, roll: 0), .stop])
    let newer = try await c.requestLease(source: .agent("nuevo"), zone: "mesa", seconds: 5)
    await c.release(lease: l)
    #expect(await c.activeLease?.id == newer.id)
}

@Test func envelopeRejectsBoundaryAndForbiddenCrossing() throws {
    let z = Zone(name: "ancha", yaw: -20...20, pitch: -20...20)
    let forbidden = Zone(name: "privada", yaw: 0.7...1, pitch: -1...1, forbidden: true)
    #expect(throws: NavigationError.unsafePath) {
        try NavigationSafety.check(pose: Pose(), velocity: Pose(yaw: 6), zone: z,
                                   forbidden: [forbidden], limits: NavigationLimits())
    }
    #expect(throws: NavigationError.unsafePath) {
        try NavigationSafety.check(pose: Pose(yaw: 19), velocity: Pose(yaw: 6), zone: z,
                                   forbidden: [], limits: NavigationLimits())
    }
    try NavigationSafety.check(pose: Pose(), velocity: Pose(yaw: -2), zone: z,
                               forbidden: [forbidden], limits: NavigationLimits())
}

@Test func navigationAlsoRespectsControllerSpeedPolicy() async throws {
    let dev = OrderedDevice()
    let clock = ManualClock()
    var policy = makePolicy()
    policy.maxSpeed = 1
    let c = GimbalController(device: dev, policy: policy, now: { clock.now() })
    let lease = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 5)
    await #expect(throws: SafetyViolation.speedTooHigh(limit: 1, requested: 2)) {
        try await c.navigationPulse(Pose(yaw: 2), source: lease.source, lease: lease)
    }
    #expect(await dev.commands.isEmpty)
}
