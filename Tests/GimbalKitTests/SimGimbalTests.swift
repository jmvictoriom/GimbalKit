import Foundation
import Testing
import GimbalKit
import GimbalKitSim

struct Boom: Error, Equatable {}

@Test func simRecordsCommandsAndIntegratesSpeed() async throws {
    let sim = SimGimbal()
    try await sim.send(.speed(yaw: 10, pitch: -5, roll: 0))
    await sim.advance(seconds: 2)
    let pose = await sim.pose
    #expect(pose == Pose(yaw: 20, pitch: -10, roll: 0))
    try await sim.send(.stop)
    await sim.advance(seconds: 5)
    #expect(await sim.pose == pose)
    #expect(await sim.commands.count == 2)
}

@Test func simAbsoluteMovesImmediately() async throws {
    let sim = SimGimbal()
    try await sim.send(.absolute(Pose(yaw: 40, pitch: 10), seconds: 1))
    #expect(await sim.currentPose() == Pose(yaw: 40, pitch: 10))
}

@Test func simWithoutPoseFeedbackHidesPose() async {
    let sim = SimGimbal(capabilities: [.speedControl])
    #expect(await sim.currentPose() == nil)
}

@Test func simCanFailOnce() async throws {
    let sim = SimGimbal()
    await sim.failNextSend(with: Boom())
    await #expect(throws: Boom.self) { try await sim.send(.stop) }
    try await sim.send(.stop)
    #expect(await sim.commands == [.stop])
}

@Test func manualClockAdvances() {
    let clock = ManualClock()
    let t0 = clock.now()
    clock.advance(2.5)
    #expect(clock.now().timeIntervalSince(t0) == 2.5)
}
