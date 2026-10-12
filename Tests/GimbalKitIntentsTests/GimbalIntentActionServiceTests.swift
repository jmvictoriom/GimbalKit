import Foundation
import Testing
import GimbalKit
import GimbalKitMCP
import GimbalHostSupport
@testable import GimbalKitIntents

@Suite struct GimbalIntentActionServiceTests {
    @Test func lookCapturesTokenBeforeConnectionWait() async throws {
        let runtime = IntentRuntimeFake()
        let token = runtime.motionStopCounter.read()
        let result = try await GimbalIntentActionService.look(zone: "mesa", runtime: runtime) {
            #expect(await runtime.lookCalls == 0)
            #expect(runtime.motionStopCounter.read() == token)
        }
        #expect(await runtime.receivedToken == token)
        #expect(await runtime.lookCalls == 1)
        #expect(result.arrivalPose == Pose(yaw: 0, pitch: 0))
    }

    @Test func stopDuringConnectionWaitPreventsLook() async throws {
        let runtime = IntentRuntimeFake()
        let token = runtime.motionStopCounter.read()
        await #expect(throws: NavigationError.interrupted) {
            try await GimbalIntentActionService.look(zone: "mesa", runtime: runtime) {
                await runtime.humanStop()
            }
        }
        #expect(await runtime.receivedToken == token)
        #expect(await runtime.lookCalls == 0)
        #expect(await runtime.stopCalls == 1)
    }

    @Test func timedOutWaitNeverCallsLook() async throws {
        let runtime = IntentRuntimeFake()
        await #expect(throws: PhoneConnectionError.timedOut) {
            try await GimbalIntentActionService.look(zone: "mesa", runtime: runtime) {
                throw PhoneConnectionError.timedOut
            }
        }
        #expect(await runtime.receivedToken == nil)
        #expect(await runtime.lookCalls == 0)
    }

    @Test func cancellationDuringWaitNeverCallsLook() async throws {
        let runtime = IntentRuntimeFake(), gate = IntentConfirmationGate()
        let look = Task {
            try await GimbalIntentActionService.look(zone: "mesa", runtime: runtime) {
                await gate.wait()
                // This wait deliberately returns successfully after cancellation.
            }
        }
        #expect(await intentEventually { await gate.waiting })
        look.cancel()
        await gate.resume()
        await #expect(throws: CancellationError.self) { try await look.value }
        #expect(await runtime.receivedToken == nil)
        #expect(await runtime.lookCalls == 0)
    }

    @Test func stopAndStatusWorkWithoutConnection() async throws {
        let runtime = IntentRuntimeFake()
        await GimbalIntentActionService.stop(runtime: runtime)
        #expect(await runtime.stopCalls == 1)
        #expect(runtime.motionStopCounter.read() == 1)
        let status = try await GimbalIntentActionService.status(runtime: runtime)
        #expect(!status.connected)
        #expect(await runtime.lookCalls == 0)
        #expect(GimbalIntentActionService.statusSummary(status) ==
            "Conexión: Desconectada. Batería: no disponible. pose no disponible.")
        let connected = GimbalStatus(connected: true, referenceReady: true,
            battery: BatteryStatus(percent: 75, charging: false), pose: Pose(yaw: 3, pitch: 4), lease: nil)
        #expect(GimbalIntentActionService.statusSummary(connected) ==
            "Conexión: Conectada. Batería: 75%. yaw 3.0°, pitch 4.0°.")
    }

    @Test func cancelledSaveShowsThePreparedDraftWithoutPersisting() async throws {
        let draft = try await makeIntentZoneDraft()
        let runtime = IntentRuntimeFake(draft: draft)
        await #expect(throws: CancellationError.self) {
            try await GimbalIntentActionService.saveZone(name: "mesa", runtime: runtime) { shown in
                expectSameIntentDraft(shown, draft)
                throw CancellationError()
            }
        }
        #expect(await runtime.prepares == 1)
        #expect(await runtime.confirms == 0)
        #expect(await runtime.persisted.isEmpty)
    }

    @Test func acceptedSaveConfirmsExactlyTheShownDraft() async throws {
        let draft = try await makeIntentZoneDraft()
        let runtime = IntentRuntimeFake(draft: draft)
        try await GimbalIntentActionService.saveZone(name: "mesa", runtime: runtime) { shown in
            expectSameIntentDraft(shown, draft)
        }
        #expect(await runtime.prepares == 1)
        #expect(await runtime.confirms == 1)
        expectSameIntentDraft(try #require(await runtime.confirmed), draft)
        #expect(await runtime.persisted == [ZoneRecord(draft.zone)])
    }

    @Test func saveRejectsChangedSession() async throws {
        let draft = try await makeIntentZoneDraft()
        let runtime = IntentRuntimeFake(draft: draft)
        await #expect(throws: NavigationError.interrupted) {
            try await GimbalIntentActionService.saveZone(name: "mesa", runtime: runtime) { shown in
                expectSameIntentDraft(shown, draft)
                await runtime.changeSession()
            }
        }
        #expect(await runtime.confirms == 1)
        #expect(await runtime.persisted.isEmpty)
    }

    @Test func saveRejectsChangedPose() async throws {
        let draft = try await makeIntentZoneDraft()
        let runtime = IntentRuntimeFake(draft: draft)
        await #expect(throws: NavigationError.interrupted) {
            try await GimbalIntentActionService.saveZone(name: "mesa", runtime: runtime) { shown in
                expectSameIntentDraft(shown, draft)
                await runtime.changePose()
            }
        }
        #expect(await runtime.confirms == 1)
        #expect(await runtime.persisted.isEmpty)
    }
}

private actor IntentRuntimeFake: GimbalIntentRuntime {
    nonisolated let motionStopCounter = MotionStopCounter()
    private let draft: ZoneDraft?
    private var session: UUID?
    private var pose: Pose?
    private(set) var receivedToken: UInt64?
    private(set) var lookCalls = 0
    private(set) var stopCalls = 0
    private(set) var prepares = 0
    private(set) var confirms = 0
    private(set) var confirmed: ZoneDraft?
    private(set) var persisted: [ZoneRecord] = []
    init(draft: ZoneDraft? = nil) { self.draft = draft; session = draft?.session; pose = draft?.pose }
    func look(zone: String, leaseSeconds: Double, stopToken: UInt64?) throws -> GimbalLookResult {
        receivedToken = stopToken
        if let stopToken, motionStopCounter.read() != stopToken { throw NavigationError.interrupted }
        lookCalls += 1
        #expect(zone == "mesa")
        #expect(leaseSeconds == 30)
        return GimbalLookResult(status: status(), arrivalPose: Pose(yaw: 0, pitch: 0))
    }
    func humanStop() { motionStopCounter.increment(); stopCalls += 1 }
    func status() -> GimbalStatus {
        GimbalStatus(connected: false, referenceReady: false, battery: nil, pose: nil, lease: nil)
    }
    func prepareZone(name: String, forbidden: Bool) throws -> ZoneDraft {
        prepares += 1
        let result = try #require(draft)
        #expect(name == result.zone.name)
        #expect(forbidden == result.zone.forbidden)
        return result
    }
    func confirmZone(_ shown: ZoneDraft) throws {
        confirms += 1
        confirmed = shown
        guard session == shown.session, let pose,
              abs(pose.yaw - shown.pose.yaw) <= 2, abs(pose.pitch - shown.pose.pitch) <= 2 else {
            throw NavigationError.interrupted
        }
        persisted.append(ZoneRecord(shown.zone))
    }
    func changeSession() { session = UUID() }
    func changePose() { pose = Pose(yaw: (pose?.yaw ?? 0) + 3, pitch: pose?.pitch ?? 0) }
}

private actor IntentConfirmationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func wait() async {
        await withCheckedContinuation { continuation = $0; waiting = true }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private func expectSameIntentDraft(_ lhs: ZoneDraft, _ rhs: ZoneDraft) {
    #expect(lhs.id == rhs.id)
    #expect(lhs.session == rhs.session)
    #expect(ZoneRecord(lhs.zone) == ZoneRecord(rhs.zone))
    #expect(lhs.pose == rhs.pose)
}

private func intentEventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<10_000 { if await condition() { return true }; await Task.yield() }
    return false
}

// Generate the draft through the public runtime API; its memberwise init is internal.
private func makeIntentZoneDraft() async throws -> ZoneDraft {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = IntentDraftLink()
    let runtime = HostRuntime(makeLink: { link }, store: ZoneStore(url: root),
        clock: RuntimeClock(now: { Date(timeIntervalSince1970: 0) }, sleep: { _ in
            let (stream, _) = AsyncStream.makeStream(of: Void.self)
            for await _ in stream { break }
            try Task.checkCancellation()
        }))
    try await runtime.start()
    #expect(await intentEventually { (try? await runtime.status().connected) == true })
    await link.attitude()
    #expect(await intentEventually { (try? await runtime.status().pose) != nil })
    let draft = try await runtime.prepareZone(name: "mesa")
    await runtime.shutdown()
    return draft
}

private actor IntentDraftLink: HostLink {
    nonisolated let notifications: AsyncStream<[UInt8]>
    nonisolated let disconnects: AsyncStream<Void>
    private let bytes: AsyncStream<[UInt8]>.Continuation
    private let disconnected: AsyncStream<Void>.Continuation
    init() {
        (notifications, bytes) = AsyncStream.makeStream(of: [UInt8].self)
        (disconnects, disconnected) = AsyncStream.makeStream(of: Void.self)
    }
    func connect() {}
    func disconnect() { bytes.finish(); disconnected.finish() }
    func write(_ bytes: [UInt8]) {}
    func attitude() {
        let hex = "553e044b04026e7c00040501f9fcff000084000300200132c503002c1800000c005403e36ab83eb4debbbea1fe193f98821cbf000000000100000000f6bc"
        bytes.yield(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}
