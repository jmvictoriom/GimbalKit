import Foundation
import Testing
@testable import GimbalKit

@Test func policyFindsZonesByName() {
    let policy = SafetyPolicy(maxSpeed: 60, maxLeaseSeconds: 30, deadmanSeconds: 0.5, zones: [
        Zone(name: "mesa", yaw: -30...30, pitch: -20...20),
        Zone(name: "baño", yaw: 120...180, pitch: -90...90, forbidden: true),
    ])
    #expect(policy.zone(named: "mesa")?.name == "mesa")
    #expect(policy.zone(named: "nada") == nil)
    #expect(policy.forbiddenZone(containing: Pose(yaw: 150, pitch: 0))?.name == "baño")
    #expect(policy.forbiddenZone(containing: Pose(yaw: 0, pitch: 0)) == nil)
}

@Test func defaultPolicyIsConservative() {
    let policy = SafetyPolicy.default
    #expect(policy.maxSpeed == 60)
    #expect(policy.maxLeaseSeconds == 30)
    #expect(policy.deadmanSeconds == 0.5)
    #expect(policy.zones.isEmpty)
}

@Test func auditLogKeepsOnlyLatestEntriesUpToCapacity() async {
    let log = AuditLog(capacity: 3)
    for i in 0..<5 {
        await log.record(AuditEntry(date: Date(timeIntervalSince1970: Double(i)), source: .app,
                                    event: "e\(i)", outcome: .accepted))
    }
    let events = await log.entries().map(\.event)
    #expect(events == ["e2", "e3", "e4"])
}
