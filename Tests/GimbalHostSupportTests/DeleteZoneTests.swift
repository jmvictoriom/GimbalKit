import Foundation
import Testing
import GimbalKit
@testable import GimbalHostSupport

@Suite struct DeleteZoneTests {
    @Test func deletesPersistsKeepsOtherZonesAndReferenceAndUpdatesController() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ZoneStore(url: root.appendingPathComponent("zones.json"))
        let removed = Zone(name: "mesa", yaw: -10...10, pitch: -10...10)
        let retained = Zone(name: "pared", yaw: 20...40, pitch: -5...5, forbidden: true)
        try await store.save([removed, retained])
        let link = FakeLink(), sleeper = StepSleeper()
        let runtime = HostRuntime(makeLink: { link }, store: store,
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        try await runtime.start()
        #expect(await eventually { (try? await runtime.status().connected) == true })
        await link.attitude()
        #expect(await eventually { (try? await runtime.status().pose) != nil })
        try await runtime.confirmReference(runtime.prepareReference())
        try await runtime.deleteZone(name: "mesa")
        #expect(await runtime.zones() == [ZoneRecord(retained)])
        #expect(try await store.load() == [retained])
        #expect(try await runtime.status().referenceReady)
        #expect(await runtime.auditEntries().contains { $0.event == "zone deleted: mesa" })
        await #expect(throws: SafetyViolation.unknownZone("mesa")) {
            try await runtime.look(zone: "mesa", leaseSeconds: 30)
        }
        await runtime.shutdown()
    }

    @Test func unknownZoneDoesNotChangeFileOrReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("zones.json"), store = ZoneStore(url: url)
        let zone = Zone(name: "mesa", yaw: -10...10, pitch: -10...10)
        try await store.save([zone])
        let link = FakeLink(fails: true), sleeper = StepSleeper()
        let runtime = HostRuntime(makeLink: { link }, store: store,
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        try await runtime.start()
        let bytes = try Data(contentsOf: url)
        await #expect(throws: ZoneStoreError.invalidZone) { try await runtime.deleteZone(name: "otra") }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(await runtime.zones() == [ZoneRecord(zone)])
        #expect(try await runtime.status().referenceReady == false)
        // También se puede borrar sin conexión, sin confirmar implícitamente una referencia.
        try await runtime.deleteZone(name: "mesa")
        #expect(try await store.load().isEmpty)
        #expect(try await runtime.status().referenceReady == false)
        await runtime.shutdown()
    }

    @Test func rejectsDeletionDuringLook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = VariableAttitudeHostLink(), sleeper = StepSleeper()
        let store = ZoneStore(url: root.appendingPathComponent("zones.json"))
        let runtime = HostRuntime(makeLink: { link }, store: store,
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        try await runtime.start()
        #expect(await eventually { (try? await runtime.status().connected) == true })
        await link.attitude(yaw: 0)
        #expect(await eventually { (try? await runtime.status().pose) != nil })
        let draft = try await runtime.prepareZone(name: "mesa")
        try await runtime.confirmZone(draft)
        await link.attitude(yaw: 5)
        #expect(await eventually { abs(((try? await runtime.status().pose?.yaw) ?? 0) - 5) < 0.001 })
        let look = Task { try await runtime.look(zone: "mesa", leaseSeconds: 30) }
        #expect(await eventually { (try? await runtime.status().lease) != nil })
        await #expect(throws: NavigationError.busy) { try await runtime.deleteZone(name: "mesa") }
        #expect(try await store.load() == [draft.zone])
        await runtime.humanStop()
        look.cancel()
        _ = await look.result
        await runtime.shutdown()
    }

    @Test func persistenceFailureKeepsInMemoryZone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("zones.json"), store = ZoneStore(url: url)
        let zone = Zone(name: "mesa", yaw: -10...10, pitch: -10...10)
        try await store.save([zone])
        let link = FakeLink(fails: true), sleeper = StepSleeper()
        let runtime = HostRuntime(makeLink: { link }, store: store,
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        try await runtime.start()
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await runtime.deleteZone(name: "mesa") }
        #expect(await runtime.zones() == [ZoneRecord(zone)])
        await runtime.shutdown()
    }
}
