import Testing
@testable import GimbalKit

@Test func zoneContainsPoseInsideRanges() {
    let zone = Zone(name: "mesa", yaw: -30...30, pitch: -20...20)
    #expect(zone.contains(Pose(yaw: 0, pitch: 0)))
    #expect(zone.contains(Pose(yaw: 30, pitch: -20)))
    #expect(!zone.contains(Pose(yaw: 31, pitch: 0)))
    #expect(!zone.contains(Pose(yaw: 0, pitch: 25)))
}

@Test func zoneRejectsNonFinitePose() {
    let zone = Zone(name: "mesa", yaw: -30...30, pitch: -20...20)
    #expect(!zone.contains(Pose(yaw: .nan, pitch: 0)))
    #expect(!zone.contains(Pose(yaw: 0, pitch: .infinity)))
}

@Test func onlyPhysicalAndAppSourcesArePrivileged() {
    #expect(ControlSource.physical.isPrivileged)
    #expect(ControlSource.app.isPrivileged)
    #expect(!ControlSource.shortcut.isPrivileged)
    #expect(!ControlSource.agent("claude").isPrivileged)
}

@Test func capabilitiesCombine() {
    let caps: Capabilities = [.speedControl, .poseFeedback]
    #expect(caps.contains(.speedControl))
    #expect(!caps.contains(.absoluteControl))
}
