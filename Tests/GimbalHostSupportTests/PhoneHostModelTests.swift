import Foundation
import Testing
import GimbalKit
@testable import GimbalHostSupport

@Suite struct PhoneHostModelTests {
    @Test func environmentStartsWithoutCreatingAView() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = FakeLink(), sleeper = StepSleeper()
        let environment = PhoneHostEnvironment(makeLink: { link }, store: ZoneStore(url: root),
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        #expect(environment.runtime.motionStopCounter === environment.motionStopCounter)
        try await environment.start()
        #expect(await eventually { (try? await environment.runtime.status().connected) == true })
        await environment.runtime.shutdown()
    }

    @Test func connectionGateTimesOutWithoutMovement() async throws {
        let link = FakeLink(fails: true), sleeper = StepSleeper()
        let environment = PhoneHostEnvironment(makeLink: { link },
            store: ZoneStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        let wait = Task { try await environment.waitUntilConnected() }
        #expect(await eventually { await sleeper.requested.contains(0.1) })
        await sleeper.advance(10)
        await #expect(throws: PhoneConnectionError.timedOut) { try await wait.value }
        #expect(await link.writes.isEmpty)
        await environment.runtime.shutdown()
    }

    @Test func connectionGateCancelsWhileSleeping() async throws {
        let link = FakeLink(fails: true), sleeper = StepSleeper()
        let environment = PhoneHostEnvironment(makeLink: { link },
            store: ZoneStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        let wait = Task { try await environment.waitUntilConnected() }
        #expect(await eventually { await sleeper.requested.contains(0.1) })
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.value }
        #expect(await link.writes.isEmpty)
        await environment.runtime.shutdown()
    }

    @Test func connectionGateCancelsDuringConnectedStatus() async throws {
        let link = FakeLink(), sleeper = StepSleeper(), probe = PhoneStatusCancellationProbe()
        let environment = PhoneHostEnvironment(makeLink: { link },
            store: ZoneStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            clock: RuntimeClock(now: { probe.read(); return sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        try await environment.start()
        #expect(await eventually { (try? await environment.runtime.status().connected) == true })
        await link.attitude()
        #expect(await eventually { (try? await environment.runtime.status().pose) != nil })
        let (signal, resume) = AsyncStream.makeStream(of: Void.self)
        let wait = Task {
            for await _ in signal { break }
            try await environment.waitUntilConnected()
        }
        // First read captures the deadline; the second happens inside status().
        probe.arm { wait.cancel() }
        resume.yield(()); resume.finish()
        await #expect(throws: CancellationError.self) { try await wait.value }
        #expect(probe.fired)
        await environment.runtime.shutdown()
    }

    @Test @MainActor func phoneModelConfirmsOnlyTheVisibleDraftAndStopsOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ZoneStore(url: root), link = FakeLink(), sleeper = StepSleeper()
        let environment = PhoneHostEnvironment(makeLink: { link }, store: store,
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        let model = PhoneHostModel(environment: environment)
        await model.humanStop()
        #expect(environment.motionStopCounter.read() == 1)
        await model.start()
        #expect(await eventually { (try? await environment.runtime.status().connected) == true })
        await link.attitude()
        #expect(await eventually { (try? await environment.runtime.status().pose) != nil })
        await model.refresh()
        #expect(model.status.connected)
        #expect(model.zones.isEmpty)
        let cancelled = try #require(await model.prepareZone(name: "cancelada"))
        #expect(model.zoneDraft?.id == cancelled.id)
        model.cancelZone(cancelled)
        #expect(model.zoneDraft == nil)
        await model.confirmZone(cancelled)
        #expect(try await store.load().isEmpty)
        let draft = try #require(await model.prepareZone(name: "mesa"))
        #expect(model.zoneDraft?.id == draft.id)
        #expect(model.zoneDraft?.session == draft.session)
        #expect(model.zoneDraft?.pose == draft.pose)
        await model.confirmZone(draft)
        #expect(try await store.load().map(ZoneRecord.init) == [ZoneRecord(draft.zone)])
        #expect(model.zoneDraft == nil)
        #expect(model.zones == [ZoneRecord(draft.zone)])
        await model.prepareReference()
        #expect(model.referenceDraft != nil)
        await model.confirmReference()
        #expect(model.status.referenceReady)
        await model.humanStop()
        #expect(environment.motionStopCounter.read() == 2)
        #expect(model.audit.contains { $0.event == "stop" })
        await model.shutdown()
    }

    @Test(arguments: [false, true]) @MainActor
    func phoneDraftRejectsChangedPoseOrSession(reconnect: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ZoneStore(url: root), link = VariableAttitudeHostLink(), next = VariableAttitudeHostLink()
        let sleeper = StepSleeper(), factory = LinkFactory([link, next])
        let environment = PhoneHostEnvironment(makeLink: { factory.next() }, store: store,
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        let model = PhoneHostModel(environment: environment)
        try await environment.start()
        #expect(await eventually { (try? await environment.runtime.status().connected) == true })
        await link.attitude(yaw: 0)
        #expect(await eventually { (try? await environment.runtime.status().pose) != nil })
        let draft = try #require(await model.prepareZone(name: "mesa"))
        if reconnect {
            await link.drop()
            #expect(await eventually { await sleeper.requested.contains(0.5) })
            await sleeper.advance(0.5)
            #expect(await eventually {
                let connected = (try? await environment.runtime.status().connected) == true
                return factory.attempts == 2 && connected
            })
            await next.attitude(yaw: 0)
            #expect(await eventually { (try? await environment.runtime.status().pose) != nil })
        } else {
            await link.attitude(yaw: 5)
            #expect(await eventually { abs(((try? await environment.runtime.status().pose?.yaw) ?? 0) - 5) < 0.001 })
        }
        await #expect(throws: NavigationError.interrupted) { try await environment.runtime.confirmZone(draft) }
        await model.confirmZone(draft)
        #expect(model.zoneDraft == nil)
        #expect(model.errorMessage != nil)
        #expect(try await store.load().isEmpty)
        await model.shutdown()
    }
}

private final class PhoneStatusCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var cancel: (@Sendable () -> Void)?
    private var didFire = false
    var fired: Bool { lock.withLock { didFire } }
    func arm(_ cancel: @escaping @Sendable () -> Void) { lock.withLock { reads = 2; self.cancel = cancel } }
    func read() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            guard cancel != nil else { return nil }
            reads -= 1
            guard reads == 0 else { return nil }
            didFire = true
            let action = cancel; cancel = nil
            return action
        }
        action?()
    }
}
