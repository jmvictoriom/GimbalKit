import Foundation
import Testing
import GimbalKit
import GimbalKitMCP
import GimbalWidgetSupport
@testable import GimbalHostSupport

private actor FakeLiveActivityController: LiveActivityControlling {
    enum Event: Sendable, Equatable {
        case start(GimbalActivityAttributes.ContentState)
        case update(GimbalActivityAttributes.ContentState)
        case end(GimbalActivityAttributes.ContentState)
    }
    private(set) var events: [Event] = []
    private var failures: Int
    private var startGate: AsyncStream<Void>?
    private var updateGate: AsyncStream<Void>?
    init(failures: Int = 0, startGate: AsyncStream<Void>? = nil, updateGate: AsyncStream<Void>? = nil) {
        self.failures = failures
        self.startGate = startGate
        self.updateGate = updateGate
    }
    func start(state: GimbalActivityAttributes.ContentState) async throws {
        events.append(.start(state))
        if let gate = startGate {
            startGate = nil
            for await _ in gate { break }
        }
        if failures > 0 { failures -= 1; throw TestLinkError.failed }
    }
    func update(state: GimbalActivityAttributes.ContentState) async {
        events.append(.update(state))
        if let gate = updateGate {
            updateGate = nil
            for await _ in gate { break }
        }
    }
    func end(state: GimbalActivityAttributes.ContentState) { events.append(.end(state)) }
}

private func activityStatus(connected: Bool = true, battery: Int? = 80, zone: String? = nil) -> GimbalStatus {
    GimbalStatus(connected: connected, referenceReady: true,
                 battery: battery.map { BatteryStatus(percent: $0, charging: true) }, pose: nil,
                 lease: zone.map { LeaseStatus(zone: $0, expiresAt: .distantFuture, remainingSeconds: 30) })
}

private func activityClock(_ sleeper: StepSleeper) -> RuntimeClock {
    RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
}

@Suite struct LiveActivityCoordinatorTests {
    @Test func contentReflectsOperationAndRetainsLastZoneWhenQuiet() {
        let moving = GimbalActivityContent.state(for: activityStatus(zone: "Mesa"), lastZone: nil)
        #expect(moving.connected)
        #expect(moving.batteryText == "80%")
        #expect(moving.charging)
        #expect(moving.operationText == "Mirando a Mesa")
        let quiet = GimbalActivityContent.state(for: activityStatus(), lastZone: moving.lastZone)
        #expect(quiet.operationText == "Quieta")
        #expect(quiet.lookingAtZone == nil)
        #expect(quiet.lastZone == "Mesa")
    }

    @Test func disconnectedContentClearsLiveTelemetryEvenWithAnOldLease() {
        let state = GimbalActivityContent.state(for: activityStatus(connected: false, zone: "Vieja"), lastZone: "Mesa")
        #expect(state.connectionText == "Desconectada")
        #expect(state.operationText == "Desconectada")
        #expect(state.batteryPercent == nil)
        #expect(!state.charging)
        #expect(state.lookingAtZone == nil)
        #expect(state.lastZone == "Mesa")
    }

    @Test func unknownBatteryAndOutOfRangeBatteryAreSafe() {
        #expect(GimbalActivityContent.state(for: activityStatus(battery: nil), lastZone: nil).batteryText == "Sin datos")
        #expect(GimbalActivityContent.state(for: activityStatus(battery: 200), lastZone: nil).batteryPercent == 100)
        #expect(GimbalActivityContent.state(for: activityStatus(battery: -1), lastZone: nil).batteryPercent == 0)
    }

    @Test func connectingStartsOneActivityAndRepeatedContentIsSuppressed() async {
        let fake = FakeLiveActivityController(), sleeper = StepSleeper()
        let coordinator = LiveActivityCoordinator(controller: fake, clock: activityClock(sleeper))
        await coordinator.receive(activityStatus())
        #expect(await eventually { await fake.events.count == 1 })
        for _ in 0..<10 { await coordinator.receive(activityStatus()) }
        await coordinator.finish()
        #expect(await fake.events == [
            .start(GimbalActivityContent.state(for: activityStatus(), lastZone: nil)),
            .end(.init(connected: false, batteryPercent: nil))
        ])
    }

    @Test func debouncePublishesLatestStateAtOneSecondWithATrailingUpdate() async {
        let fake = FakeLiveActivityController(), sleeper = StepSleeper()
        let coordinator = LiveActivityCoordinator(controller: fake, clock: activityClock(sleeper))
        await coordinator.receive(activityStatus())
        #expect(await eventually { await fake.events.count == 1 })
        await coordinator.receive(activityStatus(battery: 79, zone: "Mesa"))
        #expect(await eventually { await sleeper.requested.contains(1) })
        await sleeper.advance(0.5)
        #expect(await eventually { await sleeper.requested.contains(0.5) })
        await coordinator.receive(activityStatus(battery: 78, zone: "Ventana"))
        #expect(await fake.events.count == 1)
        await sleeper.advance(0.5)
        #expect(await eventually { await fake.events.count == 2 })
        #expect(await fake.events.last == .update(GimbalActivityContent.state(for: activityStatus(battery: 78, zone: "Ventana"), lastZone: nil)))
        await coordinator.finish()
    }

    @Test func disconnectCancelsDebounceAndEndsWithoutWaitingASecond() async {
        let fake = FakeLiveActivityController(), sleeper = StepSleeper()
        let coordinator = LiveActivityCoordinator(controller: fake, clock: activityClock(sleeper))
        await coordinator.receive(activityStatus())
        #expect(await eventually { await fake.events.count == 1 })
        await coordinator.receive(activityStatus(zone: "Mesa"))
        #expect(await eventually { await sleeper.requested.contains(1) })
        await coordinator.finish()
        #expect(await fake.events.count == 2)
        #expect(await fake.events.last == .end(.init(connected: false, batteryPercent: nil, lastZone: "Mesa")))
        await sleeper.advance(10)
        await coordinator.finish()
        #expect(await fake.events.count == 2)
    }

    @Test func disconnectDuringSuspendedStartEndsAfterStartCompletes() async {
        let (gate, resume) = AsyncStream.makeStream(of: Void.self)
        let fake = FakeLiveActivityController(startGate: gate)
        let coordinator = LiveActivityCoordinator(controller: fake)
        await coordinator.receive(activityStatus())
        #expect(await eventually { await fake.events.count == 1 })
        await coordinator.receive(activityStatus(connected: false))
        resume.yield(()); resume.finish()
        await coordinator.finish()
        #expect(await fake.events.last == .end(.init(connected: false, batteryPercent: nil)))
        #expect(await fake.events.count == 2)
    }

    @Test func briefDisconnectDuringStartIsPreservedEvenIfAlreadyReconnected() async {
        let (gate, resume) = AsyncStream.makeStream(of: Void.self)
        let fake = FakeLiveActivityController(startGate: gate)
        let coordinator = LiveActivityCoordinator(controller: fake)
        await coordinator.receive(activityStatus())
        #expect(await eventually { await fake.events.count == 1 })
        await coordinator.receive(activityStatus(connected: false))
        await coordinator.receive(activityStatus(battery: 70))
        resume.yield(()); resume.finish()
        #expect(await eventually { await fake.events.count == 3 })
        #expect(await fake.events == [
            .start(GimbalActivityContent.state(for: activityStatus(), lastZone: nil)),
            .end(.init(connected: false, batteryPercent: nil)),
            .start(GimbalActivityContent.state(for: activityStatus(battery: 70), lastZone: nil))
        ])
        await coordinator.finish()
    }

    @Test func disconnectDuringSuspendedUpdateCannotResurrectActivity() async {
        let (gate, resume) = AsyncStream.makeStream(of: Void.self)
        let fake = FakeLiveActivityController(updateGate: gate), sleeper = StepSleeper()
        let coordinator = LiveActivityCoordinator(controller: fake, clock: activityClock(sleeper))
        await coordinator.receive(activityStatus())
        #expect(await eventually { await fake.events.count == 1 })
        await coordinator.receive(activityStatus(zone: "Mesa"))
        #expect(await eventually { await sleeper.requested.contains(1) })
        await sleeper.advance(1)
        #expect(await eventually { await fake.events.count == 2 })
        await coordinator.receive(activityStatus(connected: false))
        resume.yield(()); resume.finish()
        await coordinator.finish()
        #expect(await fake.events.count == 3)
        #expect(await fake.events.last == .end(.init(connected: false, batteryPercent: nil, lastZone: "Mesa")))
    }

    @Test func initialDisconnectedObservationCleansRestoredActivitiesOnce() async {
        let fake = FakeLiveActivityController()
        let coordinator = LiveActivityCoordinator(controller: fake)
        await coordinator.finish()
        await coordinator.finish()
        #expect(await fake.events == [.end(.init(connected: false, batteryPercent: nil))])
    }

    @Test func reconnectStartsANewActivityAndKeepsLastZone() async {
        let fake = FakeLiveActivityController()
        let coordinator = LiveActivityCoordinator(controller: fake)
        await coordinator.receive(activityStatus(zone: "Mesa"))
        #expect(await eventually { await fake.events.count == 1 })
        await coordinator.finish()
        await coordinator.receive(activityStatus())
        #expect(await eventually { await fake.events.count == 3 })
        #expect(await fake.events.last == .start(GimbalActivityContent.state(for: activityStatus(), lastZone: "Mesa")))
        await coordinator.finish()
    }

    @Test func failedStartRetriesNoFasterThanOnceASecond() async {
        let fake = FakeLiveActivityController(failures: 1), sleeper = StepSleeper()
        let coordinator = LiveActivityCoordinator(controller: fake, clock: activityClock(sleeper))
        await coordinator.receive(activityStatus())
        #expect(await eventually { await fake.events.count == 1 })
        await coordinator.receive(activityStatus())
        #expect(await eventually { await sleeper.requested.contains(1) })
        #expect(await fake.events.count == 1)
        await sleeper.advance(1)
        #expect(await eventually { await fake.events.count == 2 })
        await coordinator.finish()
        #expect(await fake.events.count == 3)
    }

    @Test func idleActivityRenewsFreshnessAfterFifteenSeconds() async {
        let fake = FakeLiveActivityController(), sleeper = StepSleeper()
        let coordinator = LiveActivityCoordinator(controller: fake, clock: activityClock(sleeper))
        await coordinator.receive(activityStatus())
        #expect(await eventually { await fake.events.count == 1 })
        await sleeper.advance(15)
        await coordinator.receive(activityStatus())
        #expect(await eventually { await fake.events.count == 2 })
        #expect(await fake.events.last == .update(GimbalActivityContent.state(for: activityStatus(), lastZone: nil)))
        await coordinator.finish()
    }

    @Test func snapshotRoundTripsAtomicallyAndExpiresAtThirtySeconds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GimbalWidgetSnapshotStore(url: root.appendingPathComponent("status.json"))
        #expect(store.read() == nil)
        let date = Date(timeIntervalSince1970: 100)
        let snapshot = GimbalWidgetSnapshot(state: GimbalActivityContent.state(for: activityStatus(zone: "Mesa"), lastZone: nil), updatedAt: date)
        try store.write(snapshot)
        #expect(store.read() == snapshot)
        #expect(!snapshot.isStale(at: date.addingTimeInterval(29)))
        #expect(snapshot.isStale(at: date.addingTimeInterval(30)))
        #expect(snapshot.isStale(at: date.addingTimeInterval(-1)))
        try Data("corrupt".utf8).write(to: store.url)
        #expect(store.read() == nil)
    }

    @Test func observerReadsRuntimeWithoutAViewAndEndsOnDisconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = FakeLink(), sleeper = StepSleeper(), fake = FakeLiveActivityController()
        let runtime = HostRuntime(makeLink: { link }, store: ZoneStore(url: root), clock: activityClock(sleeper))
        let coordinator = LiveActivityCoordinator(controller: fake, clock: activityClock(sleeper), initialLastZone: "Mesa")
        let observer = PhoneActivityObserver(runtime: runtime, coordinator: coordinator, clock: activityClock(sleeper), initialLastZone: "Mesa")
        try await runtime.start()
        #expect(await eventually { (try? await runtime.status().connected) == true })
        await observer.refresh()
        #expect(await eventually { await fake.events.count == 1 })
        #expect(await fake.events.first == .start(.init(connected: true, batteryPercent: nil, lastZone: "Mesa")))
        await link.drop()
        #expect(await eventually { (try? await runtime.status().connected) == false })
        await observer.refresh()
        await observer.stop()
        #expect(await fake.events.last == .end(.init(connected: false, batteryPercent: nil, lastZone: "Mesa")))
        await runtime.shutdown()
    }
}
