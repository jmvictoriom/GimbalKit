import Foundation
import Testing
import GimbalKit
import GimbalKitSim

private let agent = ControlSource.agent("claude")

@Test func deadmanStopsMotionWhenCommandsStopArriving() async throws {
    let (c, sim, clock) = makeController()
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 20)
    try await c.send(.speed(yaw: 10, pitch: 0, roll: 0), source: agent, lease: lease)
    clock.advance(0.4)
    await c.tick()
    #expect(await sim.commands.last == .speed(yaw: 10, pitch: 0, roll: 0))
    clock.advance(0.2)
    await c.tick()
    #expect(await sim.commands.last == .stop)
}

@Test func tickDoesNotSpamStopsWhenNothingMoves() async throws {
    let (c, sim, clock) = makeController()
    for _ in 0..<5 {
        clock.advance(1)
        await c.tick()
    }
    #expect(await sim.commands.isEmpty)
}

@Test func tickStopsWhenMotionLeavesLeasedZone() async throws {
    let (c, sim, _) = makeController()
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 20)
    try await c.send(.speed(yaw: 60, pitch: 0, roll: 0), source: agent, lease: lease)
    await sim.advance(seconds: 1)   // yaw 60 > 30: fuera de «mesa»
    await c.tick()
    #expect(await sim.commands.last == .stop)
}

@Test func tickRevokesExpiredLeaseAndStops() async throws {
    let (c, sim, clock) = makeController()
    _ = try await c.requestLease(source: agent, zone: "mesa", seconds: 5)
    clock.advance(6)
    await c.tick()
    #expect(await sim.commands.last == .stop)
    #expect(await c.activeLease == nil)
}

@Test func physicalStopRevokesAgentLeaseButAgentStopKeepsOthers() async throws {
    let (c, sim, _) = makeController()
    _ = try await c.requestLease(source: agent, zone: "mesa", seconds: 20)
    await c.stop(source: .agent("otro"))
    #expect(await c.activeLease != nil)
    await c.stop(source: .physical)
    #expect(await c.activeLease == nil)
    #expect(await sim.commands.filter { $0 == .stop }.count == 2)
}

@Test func disconnectClearsLeaseAndIsAudited() async throws {
    let (c, _, _) = makeController()
    _ = try await c.requestLease(source: agent, zone: "mesa", seconds: 20)
    await c.deviceDisconnected()
    #expect(await c.activeLease == nil)
    #expect(await c.audit.entries().contains { $0.event == "device disconnected" })
}

@Test func stopStillWorksWhenDeviceFails() async {
    let (c, sim, _) = makeController()
    await sim.failNextSend(with: Boom())
    await c.stop(source: .app)          // no debe lanzar ni colgarse
    #expect(await c.audit.entries().contains { $0.event == "stop" })
}

/// Dispositivo cuya lectura de pose se queda esperando hasta que el test la abre.
actor GatedPoseDevice: GimbalDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .absoluteControl, .poseFeedback]
    private(set) var commands: [MoveCommand] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var armed = true

    var isWaiting: Bool { gate != nil }

    func send(_ command: MoveCommand) async throws { commands.append(command) }

    func currentPose() async -> Pose? {
        if armed { await withCheckedContinuation { gate = $0 } }
        return Pose()
    }

    func open() {
        armed = false
        gate?.resume()
        gate = nil
    }
}

@Test func stopDuringPoseLookupCancelsTheInFlightSpeedCommand() async throws {
    let dev = GatedPoseDevice()
    let clock = ManualClock()
    let c = GimbalController(device: dev, policy: makePolicy(), now: { clock.now() })
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 20)
    let move = Task { try await c.send(.speed(yaw: 10, pitch: 0, roll: 0), source: agent, lease: lease) }
    while !(await dev.isWaiting) { await Task.yield() }
    await c.stop(source: .physical)
    await dev.open()
    // El lease presentado ya no está vigente (revocado por la parada): se informa como leaseExpired.
    await #expect(throws: SafetyViolation.leaseExpired) { try await move.value }
    #expect(await dev.commands == [.stop])
}
