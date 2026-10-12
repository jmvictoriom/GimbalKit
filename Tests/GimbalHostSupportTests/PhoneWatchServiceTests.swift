import Foundation
import Testing
import GimbalKit
import GimbalKitMCP
import GimbalWatchKit
@testable import GimbalHostSupport

private actor FakePhoneWatchRuntime: PhoneWatchRuntime {
    nonisolated let motionStopCounter = MotionStopCounter()
    private var savedZones = [ZoneRecord(Zone(name: "mesa", yaw: -10...10, pitch: -10...10))]
    private var pendingLooks: [Int: CheckedContinuation<GimbalLookResult, any Error>] = [:]
    private var pendingStops: [Int: CheckedContinuation<Void, Never>] = [:]
    private var admission: CheckedContinuation<Void, Never>?
    var blockAdmission = false
    var blockStops = false
    private(set) var enteredLook = false
    private(set) var lookCalls = 0
    private(set) var stopCalls = 0
    private var connected = true
    func configure(admission: Bool = false, stops: Bool = false) { blockAdmission = admission; blockStops = stops }
    func look(zone: String, leaseSeconds: Double, stopToken: UInt64?) async throws -> GimbalLookResult {
        enteredLook = true
        if blockAdmission { await withCheckedContinuation { admission = $0 } }
        if let stopToken, motionStopCounter.read() != stopToken { throw NavigationError.interrupted }
        lookCalls += 1
        let call = lookCalls
        return try await withCheckedThrowingContinuation { pendingLooks[call] = $0 }
    }
    func releaseAdmission() { admission?.resume(); admission = nil }
    func completeLook(_ call: Int = 1, error: (any Error)? = nil) {
        let pending = pendingLooks.removeValue(forKey: call)
        if let error { pending?.resume(throwing: error) }
        else { pending?.resume(returning: GimbalLookResult(status: snapshot(), arrivalPose: Pose())) }
    }
    func humanStop() async {
        motionStopCounter.increment(); stopCalls += 1
        let call = stopCalls
        if blockStops { await withCheckedContinuation { pendingStops[call] = $0 } }
    }
    func releaseStop(_ call: Int) { pendingStops.removeValue(forKey: call)?.resume() }
    private func snapshot() -> GimbalStatus {
        GimbalStatus(connected: connected, referenceReady: true,
            battery: BatteryStatus(percent: 80, charging: false), pose: Pose(), lease: nil)
    }
    func status() async throws -> GimbalStatus { snapshot() }
    func zones() async -> [ZoneRecord] { savedZones }
    func replaceZones(_ zones: [ZoneRecord]) { savedZones = zones }
    func setConnected(_ connected: Bool) { self.connected = connected }
}

private actor PhoneWatchOutputLog {
    private var values: [PhoneWatchOutput] = []
    func append(_ value: PhoneWatchOutput) { values.append(value) }
    func contains(_ event: WatchEvent) -> Bool { values.contains { if case let .event(e) = $0 { return e.event == event }; return false } }
    func statuses() -> [WatchStatus] { values.compactMap { if case let .status(s) = $0 { return s }; return nil } }
    func events() -> [WatchEvent] { values.compactMap { if case let .event(e) = $0 { return e.event }; return nil } }
}

private struct PhoneWatchFixture: Sendable {
    let runtime = FakePhoneWatchRuntime()
    let sleeper = StepSleeper()
    let log = PhoneWatchOutputLog()
    let service: PhoneWatchService
    let collector: Task<Void, Never>
    let session = UUID()
    init() {
        service = PhoneWatchService(runtime: runtime,
            clock: RuntimeClock(now: { [sleeper] in sleeper.now() }, sleep: { [sleeper] in try await sleeper.sleep($0) }))
        let service = service, log = log
        collector = Task { for await value in service.outputs { await log.append(value) } }
    }
    func request(_ seq: UInt64, _ command: WatchCommand, id: UUID? = nil, token: UInt64? = nil) -> WatchRequest {
        WatchRequest(session: session, seq: seq, operationID: id, stopToken: token, command: command)
    }
    func look(_ seq: UInt64, id: UUID = UUID(), token: UInt64 = 0) -> Task<Void, Never> {
        Task { await service.receive(request(seq, .look(zone: "mesa"), id: id, token: token)) }
    }
    func close() async { await service.shutdown(); await collector.value }
}

@Suite struct PhoneWatchServiceTests {
    @Test func outOfOrderStopStillStopsAfterNewerStatusAndNeverRegressesBarriers() async throws {
        let f = PhoneWatchFixture(); await f.service.refreshStatus()
        let id = UUID(), looking = f.look(1, id: id)
        try #require(await eventually { await f.runtime.lookCalls == 1 })
        await f.service.receive(f.request(3, .status))
        let stopID = UUID()
        await f.service.receive(f.request(2, .stop, id: stopID))
        await f.service.receive(f.request(2, .stop, id: stopID))
        #expect(await f.runtime.stopCalls == 2)
        #expect(f.runtime.motionStopCounter.read() == 2)
        await f.service.receive(f.request(1, .look(zone: "mesa"), id: id, token: 2))
        #expect(await eventually { await f.log.contains(.rejected(operationID: id, reason: .staleAfterStop)) })
        let duplicateID = UUID()
        await f.service.receive(f.request(3, .look(zone: "mesa"), id: duplicateID, token: 2))
        #expect(await eventually { await f.log.contains(.rejected(operationID: duplicateID, reason: .outOfOrder)) })
        await f.runtime.completeLook(); await looking.value
        await f.close()
        #expect(!(await f.log.events()).contains(.arrived(operationID: id, stopCounter: 0)))
    }

    @Test func duplicateSequenceBusyZoneAndQuietPeriodKeepTheirReasons() async throws {
        let f = PhoneWatchFixture(); await f.service.refreshStatus()
        let looking = f.look(1)
        try #require(await eventually { await f.runtime.lookCalls == 1 })
        for (seq, zone, reason) in [(1, "mesa", WatchRejection.outOfOrder), (2, "mesa", .busy), (3, "missing", .zoneNotFound)] {
            let id = UUID()
            await f.service.receive(f.request(UInt64(seq), .look(zone: zone), id: id, token: 0))
            #expect(await eventually { await f.log.contains(.rejected(operationID: id, reason: reason)) })
        }
        await f.service.receive(f.request(4, .stop, id: UUID()))
        let retry = UUID(); await f.service.receive(f.request(5, .look(zone: "mesa"), id: retry, token: 1))
        #expect(await eventually { await f.log.contains(.rejected(operationID: retry, reason: .quietPeriod)) })
        await f.sleeper.advance(2)
        let next = f.look(6, token: 1)
        try #require(await eventually { await f.runtime.lookCalls == 2 })
        await f.runtime.completeLook(1); await looking.value
        #expect(await f.service.watchOperationActive)
        await f.runtime.completeLook(2); await next.value; await f.close()
    }

    @Test func reachabilityLossStopsPreparationAndOpensSilenceBeforeObserver() async throws {
        let f = PhoneWatchFixture(); await f.service.refreshStatus()
        let id = UUID(), looking = f.look(1, id: id)
        try #require(await eventually { await f.runtime.lookCalls == 1 })
        await f.service.setReachable(false)
        #expect(await f.runtime.stopCalls == 1)
        #expect(f.runtime.motionStopCounter.read() == 1)
        await f.service.setReachable(true)
        let retry = UUID(); await f.service.receive(f.request(2, .look(zone: "mesa"), id: retry, token: 1))
        #expect(await eventually { await f.log.contains(.rejected(operationID: retry, reason: .quietPeriod)) })
        await f.runtime.completeLook(); await looking.value; await f.close()
        #expect(!(await f.log.events()).contains(.arrived(operationID: id, stopCounter: 0)))
    }

    @Test func stopBetweenAdmissionAndRuntimeGuardRejectsOldToken() async throws {
        let f = PhoneWatchFixture(); await f.runtime.configure(admission: true); await f.service.refreshStatus()
        let looking = f.look(1)
        try #require(await eventually { await f.runtime.enteredLook })
        #expect(await f.service.watchOperationActive)
        await f.service.receive(f.request(2, .stop, id: UUID()))
        await f.runtime.releaseAdmission(); await looking.value
        #expect(await f.runtime.lookCalls == 0)
        #expect(await f.service.watchOperationActive == false)
        await f.close()
    }

    @Test func realRuntimeOldTokenHasNoConnectionLeaseOrWrites() async throws {
        let link = FakeLink(), factory = LinkFactory([link]), counter = MotionStopCounter()
        let runtime = HostRuntime(makeLink: { factory.next() },
            store: ZoneStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            motionStopCounter: counter)
        await runtime.humanStop()
        await #expect(throws: NavigationError.interrupted) { try await runtime.look(zone: "mesa", leaseSeconds: 30, stopToken: 0) }
        #expect(factory.attempts == 0)
        #expect(try await runtime.status().lease == nil)
        #expect(await link.writes.isEmpty)
        await runtime.shutdown()
    }

    @Test func externalStopObserverInvalidatesActiveWithoutStoppingAgain() async throws {
        let f = PhoneWatchFixture(); await f.service.refreshStatus(); await f.service.startObservingStopCounter()
        let id = UUID(), looking = f.look(1, id: id)
        try #require(await eventually { await f.runtime.lookCalls == 1 })
        try #require(await eventually { await f.sleeper.requested.contains(0.025) })
        await f.runtime.humanStop(); await f.sleeper.advance(0.025)
        try #require(await eventually { await f.log.contains(.stopped(operationID: id, stopCounter: 0)) })
        #expect(await f.runtime.stopCalls == 1)
        let retry = UUID(); await f.service.receive(f.request(2, .look(zone: "mesa"), id: retry, token: 1))
        #expect(await eventually { await f.log.contains(.rejected(operationID: retry, reason: .quietPeriod)) })
        await f.runtime.completeLook(); await looking.value; await f.close()
    }

    @Test func externalStopCorrectsCompletedArrivalInContextAndQueuedStatus() async throws {
        let f = PhoneWatchFixture(); await f.service.refreshStatus()
        let id = UUID(), looking = f.look(1, id: id)
        try #require(await eventually { await f.runtime.lookCalls == 1 })
        await f.runtime.completeLook(); await looking.value; await f.service.refreshStatus()
        try #require(await eventually { await f.log.statuses().last?.terminalEvent?.event == .arrived(operationID: id, stopCounter: 0) })
        let queued = try #require(await f.log.statuses().last)
        await f.runtime.humanStop()
        var published: PhoneWatchOutput?
        await f.service.publish(.status(queued)) { published = $0 }
        guard case let .status(status) = published else { Issue.record("Missing status"); return }
        #expect(status.stopToken == 1)
        #expect(status.terminalEvent?.event == .stopped(operationID: id, stopCounter: 0))
        await f.service.refreshStatus(); await f.close()
        #expect(await f.log.statuses().last?.terminalEvent?.event == .stopped(operationID: id, stopCounter: 0))
    }

    @Test func overlappingStopsDoNotConsumeNewerExternalStopOrClearNewIdentity() async throws {
        let f = PhoneWatchFixture(); await f.runtime.configure(stops: true); await f.service.refreshStatus()
        let a = Task { await f.service.receive(f.request(1, .stop, id: UUID())) }
        try #require(await eventually { await f.runtime.stopCalls == 1 })
        await f.service.refreshStatus()
        await f.sleeper.advance(2)
        let first = f.look(2, token: 1)
        try #require(await eventually { await f.runtime.lookCalls == 1 })
        let b = Task { await f.runtime.humanStop() }
        try #require(await eventually { await f.runtime.stopCalls == 2 })
        await f.runtime.releaseStop(1); await a.value
        #expect(await f.service.watchOperationActive == false)
        let id = UUID(); await f.service.receive(f.request(3, .look(zone: "mesa"), id: id, token: 2))
        #expect(await eventually { await f.log.contains(.rejected(operationID: id, reason: .quietPeriod)) })
        await f.sleeper.advance(2)
        let secondID = UUID(), second = f.look(4, id: secondID, token: 2)
        try #require(await eventually { await f.runtime.lookCalls == 2 })
        await f.runtime.completeLook(1); await first.value
        #expect(await f.service.watchOperationActive)
        await f.runtime.releaseStop(2); await b.value
        await f.runtime.completeLook(2); await second.value; await f.close()
        #expect(await f.log.events().contains(.arrived(operationID: secondID, stopCounter: 2)))
    }

    @Test func lateStopCompletionDoesNotOverwriteNewerTerminal() async throws {
        let f = PhoneWatchFixture(); await f.runtime.configure(stops: true); await f.service.refreshStatus()
        let stop = Task { await f.service.receive(f.request(1, .stop, id: UUID())) }
        try #require(await eventually { await f.runtime.stopCalls == 1 })
        // Observe the increment while STOP is still suspended, then let its silence expire.
        await f.service.refreshStatus(); await f.sleeper.advance(2)
        let id = UUID(), looking = f.look(2, id: id, token: 1)
        try #require(await eventually { await f.runtime.lookCalls == 1 })
        await f.runtime.completeLook(); await looking.value
        await f.runtime.releaseStop(1); await stop.value
        await f.service.refreshStatus(); await f.close()
        #expect(await f.log.statuses().last?.terminalEvent?.event == .arrived(operationID: id, stopCounter: 1))
    }

    @Test func correctionOfQueuedArrivalDoesNotReplaceLaterTerminal() async throws {
        let f = PhoneWatchFixture(); await f.service.refreshStatus()
        let oldID = UUID(), first = f.look(1, id: oldID)
        try #require(await eventually { await f.runtime.lookCalls == 1 })
        await f.runtime.completeLook(); await first.value
        let old = WatchEventEnvelope(session: f.session, event: .arrived(operationID: oldID, stopCounter: 0))
        await f.runtime.humanStop(); await f.service.refreshStatus(); await f.sleeper.advance(2)
        let newID = UUID(), next = f.look(2, id: newID, token: 1)
        try #require(await eventually { await f.runtime.lookCalls == 2 })
        await f.runtime.completeLook(2); await next.value
        var sent: PhoneWatchOutput?
        await f.service.publish(.event(old)) { sent = $0 }
        #expect(sent == .event(WatchEventEnvelope(session: f.session, event: .stopped(operationID: oldID, stopCounter: 0))))
        await f.service.refreshStatus(); await f.close()
        #expect(await f.log.statuses().last?.terminalEvent?.event == .arrived(operationID: newID, stopCounter: 1))
    }

    @Test func publicationRechecksAtActualSendAndDiscardsOldStopped() async {
        let f = PhoneWatchFixture(), id = UUID()
        let old = WatchEventEnvelope(session: f.session, event: .arrived(operationID: id, stopCounter: 0))
        #expect(PhoneWatchEventPublication.decision(for: old, currentStopCounter: 0) == .send(old))
        f.runtime.motionStopCounter.increment()
        var sent: PhoneWatchOutput?
        await f.service.publish(.event(old)) { sent = $0 }
        let correction = WatchEventEnvelope(session: f.session, event: .stopped(operationID: id, stopCounter: 0))
        #expect(sent == .event(correction))
        var sends = 0
        await f.service.publish(.event(correction)) { _ in sends += 1 }
        #expect(sends == 0)
        #expect(PhoneWatchEventPublication.decision(for: correction, currentStopCounter: 0) == .send(correction))
        await f.close()
    }

    @Test func counterIncrementCannotPassBetweenValidationAndSynchronousSend() async {
        let f = PhoneWatchFixture(), order = PhoneWatchPublicationOrder()
        let started = DispatchSemaphore(value: 0)
        let (finished, done) = AsyncStream.makeStream(of: Void.self)
        let event = WatchEventEnvelope(session: f.session, event: .arrived(operationID: UUID(), stopCounter: 0))
        await f.service.publish(.event(event)) { value in
            Thread.detachNewThread {
                started.signal()
                f.runtime.motionStopCounter.increment()
                order.append("stop"); done.yield(()); done.finish()
            }
            started.wait()
            #expect(value == .event(event))
            order.append("send")
        }
        for await _ in finished { break }
        #expect(order.values == ["send", "stop"])
        await f.close()
    }

    @Test func observerRefreshesConnectionAndSavedZonesWithoutViewOrStatusRequest() async throws {
        let f = PhoneWatchFixture(); await f.runtime.setConnected(false)
        await f.service.refreshStatus(); await f.service.startObservingStopCounter()
        try #require(await eventually { await f.sleeper.requested.contains(0.025) })
        await f.runtime.setConnected(true)
        await f.runtime.replaceZones([ZoneRecord(Zone(name: "salon", yaw: 20...40, pitch: -10...10))])
        await f.sleeper.advance(0.025)
        try #require(await eventually {
            let status = await f.log.statuses().last
            return status?.zoneNames == ["salon"] && status?.connected == true
        })
        let id = UUID()
        let looking = Task { await f.service.receive(f.request(1, .look(zone: "salon"), id: id, token: 0)) }
        try #require(await eventually { await f.runtime.lookCalls == 1 })
        await f.runtime.completeLook(); await looking.value; await f.close()
    }

    @Test @MainActor func synchronousPublisherWorksOnBridgeExecutor() async {
        let f = PhoneWatchFixture()
        let old = WatchEventEnvelope(session: f.session,
            event: .arrived(operationID: UUID(), stopCounter: 0))
        f.runtime.motionStopCounter.increment()
        var sent: PhoneWatchOutput?
        let published = PhoneWatchEventPublication.publish(.event(old), stopCounter: f.service.stopCounter) {
            sent = $0
        }
        #expect(published == sent)
        if case let .event(envelope) = sent {
            if case .stopped = envelope.event {} else { Issue.record("Stale arrival was sent") }
        } else { Issue.record("Missing stopped correction") }
        await f.close()
    }

    @Test func stopAcknowledgementIsRecoverableAndTerminalReducerRunsOnlyOnce() async throws {
        let f = PhoneWatchFixture(); await f.service.refreshStatus()
        let oldID = UUID(), looking = f.look(1, id: oldID)
        try #require(await eventually { await f.runtime.lookCalls == 1 })
        let stopID = UUID()
        await f.service.receive(f.request(2, .stop, id: stopID))
        await f.runtime.completeLook(); await looking.value
        await f.service.refreshStatus(); await f.close()
        let status = try #require(await f.log.statuses().last)
        let terminal = try #require(status.terminalEvent)
        #expect(terminal.event == .stopped(operationID: stopID, stopCounter: 1))
        let recovered = try WatchMessageCodec.decodeStatus(WatchMessageCodec.encodeStatus(status))
        var reducer = WatchOperationState(); reducer.begin(stopID)
        reducer.observeStopToken(status.stopToken)
        #expect(reducer.apply(terminal.event) == terminal.event)
        #expect(reducer.apply(try #require(recovered.terminalEvent).event) == nil)
    }

    @Test func malformedStaleTokenDisconnectedAndForbiddenZoneNeverStartLook() async {
        let f = PhoneWatchFixture(); await f.service.refreshStatus()
        let malformedID = UUID()
        await f.service.rejectMalformed(session: f.session, operationID: malformedID)
        let staleID = UUID()
        await f.service.receive(f.request(1, .look(zone: "mesa"), id: staleID, token: 1))
        await f.service.setReachable(false)
        let disconnectedID = UUID()
        await f.service.receive(f.request(2, .look(zone: "mesa"), id: disconnectedID, token: 0))
        await f.service.setReachable(true)
        await f.runtime.replaceZones([ZoneRecord(Zone(name: "mesa", yaw: -10...10, pitch: -10...10, forbidden: true))])
        await f.service.refreshStatus()
        let forbiddenID = UUID()
        await f.service.receive(f.request(3, .look(zone: "mesa"), id: forbiddenID, token: 0))
        await f.close()
        #expect(await f.log.contains(.rejected(operationID: malformedID, reason: .malformed)))
        #expect(await f.log.contains(.rejected(operationID: staleID, reason: .staleAfterStop)))
        #expect(await f.log.contains(.rejected(operationID: disconnectedID, reason: .disconnected)))
        #expect(await f.log.contains(.rejected(operationID: forbiddenID, reason: .zoneNotFound)))
        #expect(await f.runtime.lookCalls == 0)
    }

    @Test(arguments: [WatchRejection.referenceRequired, .unsafePath, .stalePose, .timeout, .policyRejected])
    func navigationAndSafetyReasonsArePreserved(reason: WatchRejection) async throws {
        let f = PhoneWatchFixture(); await f.service.refreshStatus()
        let id = UUID(), looking = f.look(1, id: id)
        try #require(await eventually { await f.runtime.lookCalls == 1 })
        let error: any Error
        switch reason {
        case .referenceRequired: error = NavigationError.referenceRequired
        case .unsafePath: error = NavigationError.unsafePath
        case .stalePose: error = NavigationError.stalePose
        case .timeout: error = NavigationError.timeout
        default: error = SafetyViolation.invalidValue
        }
        await f.runtime.completeLook(error: error); await looking.value; await f.close()
        #expect(await f.log.contains(.rejected(operationID: id, reason: reason)))
    }
}

private final class PhoneWatchPublicationOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var values: [String] { lock.withLock { entries } }
}
