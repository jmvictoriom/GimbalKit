import Foundation
import Testing
import GimbalKit
import GimbalKitSim

private let agent = ControlSource.agent("claude")

@Test func leaseRejectsUnknownForbiddenAndInvalidRequests() async {
    let (c, _, _) = makeController()
    await #expect(throws: SafetyViolation.unknownZone("cocina")) { try await c.requestLease(source: agent, zone: "cocina", seconds: 5) }
    await #expect(throws: SafetyViolation.forbiddenZone("baño")) { try await c.requestLease(source: agent, zone: "baño", seconds: 5) }
    await #expect(throws: SafetyViolation.leaseTooLong(max: 30)) { try await c.requestLease(source: agent, zone: "mesa", seconds: 31) }
    for bad in [0.0, -1.0, .nan, .infinity] {
        await #expect(throws: SafetyViolation.invalidDuration) { try await c.requestLease(source: agent, zone: "mesa", seconds: bad) }
    }
}

@Test func emptyZoneListRejectsEveryLease() async {
    let (c, _, _) = makeController(zones: [])
    await #expect(throws: SafetyViolation.unknownZone("mesa")) { try await c.requestLease(source: agent, zone: "mesa", seconds: 5) }
}

@Test func agentNeedsLeaseToMove() async throws {
    let (c, sim, _) = makeController()
    await #expect(throws: SafetyViolation.noLease) {
        try await c.send(.absolute(Pose(yaw: 10, pitch: 0), seconds: 1), source: agent)
    }
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 5)
    try await c.send(.absolute(Pose(yaw: 10, pitch: 0), seconds: 1), source: agent, lease: lease)
    #expect(await sim.currentPose() == Pose(yaw: 10, pitch: 0))
}

@Test func absoluteOutsideZoneOrIntoForbiddenZoneIsRejected() async throws {
    let (c, sim, _) = makeController()
    let desk = try await c.requestLease(source: agent, zone: "mesa", seconds: 5)
    await #expect(throws: SafetyViolation.outsideZone("mesa")) {
        try await c.send(.absolute(Pose(yaw: 80, pitch: 0), seconds: 1), source: agent, lease: desk)
    }
    let wide = try await c.requestLease(source: agent, zone: "ancha", seconds: 5)
    await #expect(throws: SafetyViolation.forbiddenZone("baño")) {
        try await c.send(.absolute(Pose(yaw: 150, pitch: 0), seconds: 1), source: agent, lease: wide)
    }
    #expect(await sim.commands.isEmpty)
}

@Test func speedAndPoseValuesAreValidated() async throws {
    let (c, sim, _) = makeController()
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 5)
    await #expect(throws: SafetyViolation.speedTooHigh(limit: 60, requested: 90)) {
        try await c.send(.speed(yaw: 90, pitch: 0, roll: 0), source: agent, lease: lease)
    }
    await #expect(throws: SafetyViolation.invalidValue) {
        try await c.send(.speed(yaw: .nan, pitch: 0, roll: 0), source: agent, lease: lease)
    }
    await #expect(throws: SafetyViolation.invalidValue) {
        try await c.send(.absolute(Pose(yaw: .infinity, pitch: 0), seconds: 1), source: agent, lease: lease)
    }
    await #expect(throws: SafetyViolation.invalidValue) {
        try await c.send(.absolute(Pose(yaw: 0, pitch: 0), seconds: .nan), source: agent, lease: lease)
    }
    #expect(await sim.commands.isEmpty)
}

@Test func privilegedSourceStillRespectsSpeedLimitButNeedsNoLease() async throws {
    let (c, sim, _) = makeController()
    try await c.send(.speed(yaw: 30, pitch: 0, roll: 0), source: .app)
    await #expect(throws: SafetyViolation.speedTooHigh(limit: 60, requested: 61)) {
        try await c.send(.speed(yaw: 61, pitch: 0, roll: 0), source: .app)
    }
    #expect(await sim.commands.count == 1)
}

@Test func secondAgentGetsBusyUntilLeaseExpires() async throws {
    let (c, _, clock) = makeController()
    _ = try await c.requestLease(source: agent, zone: "mesa", seconds: 10)
    await #expect(throws: SafetyViolation.busy(holder: agent)) {
        try await c.requestLease(source: .agent("otro"), zone: "puerta", seconds: 5)
    }
    clock.advance(11)
    let second = try await c.requestLease(source: .agent("otro"), zone: "puerta", seconds: 5)
    #expect(second.zone == "puerta")
}

@Test func expiredLeaseIsReportedAsExpired() async throws {
    let (c, _, clock) = makeController()
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 5)
    clock.advance(6)
    await #expect(throws: SafetyViolation.leaseExpired) {
        try await c.send(.absolute(Pose(yaw: 0, pitch: 0), seconds: 1), source: agent, lease: lease)
    }
}

@Test func privilegedSourcePreemptsAgentLeaseAndStopsMotors() async throws {
    let (c, sim, _) = makeController()
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 20)
    try await c.send(.speed(yaw: 10, pitch: 0, roll: 0), source: agent, lease: lease)
    _ = try await c.requestLease(source: .app, zone: "puerta", seconds: 10)
    #expect(await sim.commands.last == .stop)
    await #expect(throws: SafetyViolation.noLease) {
        try await c.send(.speed(yaw: 10, pitch: 0, roll: 0), source: agent, lease: lease)
    }
}

@Test func speedNeedsPoseFeedbackForAgents() async throws {
    let (c, _, _) = makeController(capabilities: [.speedControl])
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 5)
    await #expect(throws: SafetyViolation.poseUnavailable) {
        try await c.send(.speed(yaw: 10, pitch: 0, roll: 0), source: agent, lease: lease)
    }
}

@Test func unsupportedCommandsAreRejected() async {
    let (c, _, _) = makeController(capabilities: [.speedControl])
    await #expect(throws: SafetyViolation.unsupported(.absoluteControl)) {
        try await c.send(.absolute(Pose(), seconds: 1), source: .app)
    }
}

@Test func stopIsAlwaysAllowedAndRejectionsAreAudited() async throws {
    let (c, sim, _) = makeController()
    try await c.send(.stop, source: agent)
    #expect(await sim.commands == [.stop])
    _ = try? await c.send(.speed(yaw: 1, pitch: 0, roll: 0), source: agent)
    let entries = await c.audit.entries()
    #expect(entries.contains { $0.outcome == .rejected("noLease") })
    #expect(entries.contains { $0.outcome == .accepted })
}

@Test func concurrentLeaseRequestsGrantExactlyOne() async {
    let (c, _, _) = makeController()
    let granted = await withTaskGroup(of: Bool.self) { group in
        for i in 0..<8 {
            group.addTask { (try? await c.requestLease(source: .agent("a\(i)"), zone: "mesa", seconds: 5)) != nil }
        }
        var n = 0
        for await ok in group where ok { n += 1 }
        return n
    }
    #expect(granted == 1)
}
