import Foundation
import Testing
import GimbalKit
import GimbalKitDJI
import GimbalKitSim
@testable import GimbalLabSupport

private final class FakeLabLink: LabLink, @unchecked Sendable {
    let notifications: AsyncStream<[UInt8]>
    let disconnects: AsyncStream<Void>
    private let notificationContinuation: AsyncStream<[UInt8]>.Continuation
    private let disconnectContinuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var writeHistory: [(Date, [UInt8])] = []
    var bluetoothAuthorization: LabBluetoothAuthorization { .allowed }
    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        let n = AsyncStream.makeStream(of: [UInt8].self)
        notifications = n.stream; notificationContinuation = n.continuation
        let d = AsyncStream.makeStream(of: Void.self)
        disconnects = d.stream; disconnectContinuation = d.continuation
    }
    func connect() async throws {}
    func disconnect() async { disconnectContinuation.yield(()); disconnectContinuation.finish() }
    func write(_ bytes: [UInt8]) async throws { lock.withLock { writeHistory.append((now(), bytes)) } }
    func emit(_ bytes: [UInt8]) { notificationContinuation.yield(bytes) }
    func writes() -> [(Date, [UInt8])] { lock.withLock { writeHistory } }
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("La condición no llegó a cumplirse")
}

private actor SimPoseFeedbackDevice: PoseFeedbackDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback, .battery]
    private let simulator: SimGimbal
    private let clock: ManualClock
    private var sequence: UInt64 = 0
    private var elapsed = 0.0
    private var lastReceived: Date
    init(simulator: SimGimbal, clock: ManualClock) { self.simulator = simulator; self.clock = clock; lastReceived = clock.now() }
    func advance(_ seconds: Double) async {
        await simulator.advance(seconds: seconds)
        clock.advance(seconds)
        elapsed += seconds
        while elapsed >= 0.5 { elapsed -= 0.5; sequence &+= 1; lastReceived = clock.now() }
    }
    func send(_ command: MoveCommand) async throws { try await simulator.send(command) }
    func currentPose() async -> Pose? { await simulator.currentPose() }
    func poseSample() async -> PoseSample? {
        guard let pose = await simulator.currentPose() else { return nil }
        return PoseSample(pose: pose, receivedAt: lastReceived, sequence: sequence)
    }
}

private actor ImmobilePoseFeedbackDevice: PoseFeedbackDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    private let simulator: SimGimbal
    private let clock: ManualClock
    private var sequence: UInt64 = 0
    init(simulator: SimGimbal, clock: ManualClock) { self.simulator = simulator; self.clock = clock }
    func send(_ command: MoveCommand) async throws {}
    func currentPose() async -> Pose? { await simulator.currentPose() }
    func poseSample() async -> PoseSample? {
        sequence &+= 1
        return PoseSample(pose: await simulator.currentPose() ?? Pose(), receivedAt: clock.now(), sequence: sequence)
    }
}

private actor FrozenPoseFeedbackDevice: PoseFeedbackDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    private let frozen: Pose
    private let clock: ManualClock
    init(pose: Pose, clock: ManualClock) { frozen = pose; self.clock = clock }
    func send(_ command: MoveCommand) async throws {}
    func currentPose() -> Pose? { frozen }
    func poseSample() -> PoseSample? { PoseSample(pose: frozen, receivedAt: clock.now(), sequence: 1) }
}

private actor DriftingPoseFeedbackDevice: PoseFeedbackDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    private var pose = Pose()
    private let clock: ManualClock
    private var sequence: UInt64 = 0
    init(clock: ManualClock) { self.clock = clock }
    func send(_ command: MoveCommand) async throws {}
    func currentPose() -> Pose? { pose.yaw += 0.01; return pose }
    func poseSample() -> PoseSample? {
        sequence += 1; pose.yaw += 0.01
        return PoseSample(pose: pose, receivedAt: clock.now(), sequence: sequence)
    }
}

private actor NonStoppingPoseFeedbackDevice: PoseFeedbackDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    private let clock: ManualClock
    private var origin = Date()
    private var velocity = 0.0
    private var sequence: UInt64 = 0
    init(clock: ManualClock) { self.clock = clock; origin = clock.now() }
    func send(_ command: MoveCommand) async throws {
        if case let .speed(yaw, _, _) = command { velocity = yaw; origin = clock.now() }
    }
    func currentPose() -> Pose? { Pose(yaw: velocity * clock.now().timeIntervalSince(origin)) }
    func poseSample() -> PoseSample? {
        sequence += 1
        return PoseSample(pose: currentPose() ?? Pose(), receivedAt: clock.now(), sequence: sequence)
    }
}

private actor RunawayPoseFeedbackDevice: PoseFeedbackDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    private let clock: ManualClock
    private var sequence: UInt64 = 0
    private var samples = 0
    private var stops = 0
    init(clock: ManualClock) { self.clock = clock }
    func send(_ command: MoveCommand) async throws { if command == .stop { stops += 1 } }
    func currentPose() -> Pose? { Pose(yaw: 50) }
    func poseSample() -> PoseSample? {
        sequence += 1; samples += 1
        return PoseSample(pose: Pose(yaw: samples == 1 ? 0 : 50), receivedAt: clock.now(), sequence: sequence)
    }
    func stopCount() -> Int { stops }
}

@Test func captureJSONLRoundTripsResearchRXAndTX() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("session.jsonl")
    let clock = ManualClock(Date(timeIntervalSince1970: 100))
    let recorder = LabSessionRecorder(clock: RuntimeClock(now: { clock.now() }, sleep: { _ in }))
    try await recorder.start(at: url)
    await recorder.setPhase("quieta")
    try await recorder.recordRX(hex: Real.yawA, crc: true)
    clock.advance(0.3)
    try await recorder.recordTX(yaw: 10, pitch: 0, roll: 0)
    try await recorder.stop()
    let records = try LabCaptureReader.read(Data(contentsOf: url))
    let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(whereSeparator: \.isNewline)
    #expect(records.count == 2)
    #expect(records[0].fase == "quieta" && records[0].k == "rx" && records[0].crc == true)
    #expect(records[0].hex == Real.yawA)
    #expect(records[1].k == "tx" && records[1].yaw == 10 && records[1].pitch == 0 && records[1].roll == 0)
    let rxJSON = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    let txJSON = try #require(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
    #expect(Set(rxJSON.keys) == Set(["t", "fase", "k", "crc", "hex"]))
    #expect(Set(txJSON.keys) == Set(["t", "fase", "k", "yaw", "pitch", "roll"]))
    let legacy = Data("{\"t\":0.1,\"fase\":\"pre\",\"crc\":true,\"hex\":\"abc\"}\n".utf8)
    #expect(try LabCaptureReader.read(legacy).first?.k == nil)
}

@Test @MainActor func modelCountsAndFiltersWhilePauseOnlyFreezesRows() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = ManualClock()
    let sleeper = LabTestSleeper(clock: clock)
    let model = LabModel(store: ZoneStore(url: directory.appendingPathComponent("zones.json")),
        clock: RuntimeClock(now: { clock.now() }, sleep: { seconds in
            try Task.checkCancellation()
            if seconds >= 0.29 { try await sleeper.sleep(seconds) }
            else { await Task.yield() }
        }))
    let link = FakeLabLink(now: { clock.now() })
    await model.connect(using: link)
    #expect(model.connection == .connected)
    link.emit(realBytes(Real.yawA))
    try await waitUntil { await MainActor.run { model.validFrameCount == 1 } }
    try await waitUntil { await MainActor.run { model.pose != nil } }
    clock.advance(1)
    link.emit(realBytes(Real.yawA))
    try await waitUntil { await MainActor.run { model.validFrameCount == 2 && model.updateHz > 0 } }
    #expect(abs(model.updateHz - 1) < 0.01)
    #expect((model.poseAgeSeconds ?? 10) < 0.1)
    link.emit(realBytes(Real.battery))
    try await waitUntil { await MainActor.run { model.validFrameCount == 3 && model.battery?.percent == 25 } }
    model.commandSetFilter = "04"; model.commandFilter = "05"
    #expect(model.visibleFrames.count == 2)
    model.isFrameListPaused = true
    let shown = model.frames.count
    var damaged = realBytes(Real.yawA); damaged[damaged.count - 1] ^= 1
    link.emit(damaged)
    try await waitUntil { await MainActor.run { model.invalidFrameCount == 1 } }
    #expect(model.frames.count == shown && model.invalidFrameCount == 1)
    model.startManual(axis: .yaw, direction: 1, speed: 12)
    try await waitUntil { await sleeper.hasWaiter(for: 0.30) }
    // Advance between orders, rather than racing a real sleep against Task.yield.
    // Date rounds 0.30 down at this epoch, so use a 1 µs margin in the harness.
    clock.advance(0.300001)
    await sleeper.timeAdvanced()
    try await waitUntil { link.writes().count >= 2 }
    await model.endManual()
    let writes = link.writes()
    let stop = OMRotate(yaw: 0, pitch: 0, roll: 0, time: 10, mode: .speed).frame().encoded()
    #expect(writes.count >= 3 && writes.last?.1 == stop)
    if writes.count >= 3 {
        for index in 1..<(writes.count - 1) {
            #expect(writes[index].0.timeIntervalSince(writes[index - 1].0) >= 0.3)
        }
    }
    await model.disconnect()
}

@Test func hardwareRunnerUsesSimulatorsForPassAndFailureCases() async throws {
    let clock = ManualClock()
    let simulator = SimGimbal(pose: Pose())
    let device = SimPoseFeedbackDevice(simulator: simulator, clock: clock)
    let sleeper = LabTestSleeper(clock: clock)
    let liveClock = RuntimeClock(now: { clock.now() }, sleep: { seconds in
        try Task.checkCancellation()
        if seconds > 0.3 { try await sleeper.sleep(seconds); return }
        await device.advance(seconds)
        await sleeper.timeAdvanced()
        await Task.yield()
    })
    let observingClock = RuntimeClock(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    let policy = SafetyPolicy(maxSpeed: 12, maxLeaseSeconds: 30, deadmanSeconds: 1,
        zones: [Zone(name: "banco", yaw: -20...36, pitch: -20...20)])
    let controller = GimbalController(device: device, policy: policy, now: { clock.now() })
    let link = FakeLabLink(); let buffer = LabFrameBuffer()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ZoneStore(url: directory.appendingPathComponent("zones.json"))
    try await store.save([Zone(name: "banco", yaw: -20...36, pitch: -20...20)])
    let runner = LabHardwareTestRunner(transport: link, device: device, controller: controller,
        navigator: GotoNavigator(controller: controller, clock: liveClock), store: store, frames: buffer,
        battery: { LabBattery(percent: 25, charging: false) }, clock: liveClock)
    #expect(await runner.run(.connectionTelemetry).status == .passed)
    #expect(await runner.run(.restStability).status == .passed)
    #expect(await runner.run(.battery).status == .passed)
    let before = await simulator.commands.count
    #expect(await runner.run(.yawMovement).status == .passed)
    // Cada orden SPEED de la Osmo dura ~0,5 s: un tramo de 2 s exige refrescarla cada 0,3 s (≥ 6 órdenes por tramo, 2 tramos).
    let speedCommands = await simulator.commands.dropFirst(before).filter { if case .speed = $0 { true } else { false } }
    #expect(speedCommands.count >= 12, "órdenes de velocidad enviadas: \(speedCommands.count)")
    #expect(await runner.run(.stop).status == .passed)
    #expect(await simulator.commands.contains(.stop))
    // Only navigation advances simulated time. Its safety watcher observes it.
    let zoneRunner = LabHardwareTestRunner(transport: link, device: device, controller: controller,
        navigator: GotoNavigator(controller: controller, clock: liveClock), store: store, frames: buffer,
        battery: { LabBattery(percent: 25, charging: false) }, clock: observingClock)
    await zoneRunner.setReferenceConfirmed(true)
    let departure = try #require(await device.currentPose())
    let arrival = await zoneRunner.run(.zoneGoto)
    #expect(arrival.status == .passed)
    #expect(abs(8 - departure.yaw) <= 10)
    #expect(arrival.durationSeconds < 20)
    let finalPose = try #require(await device.currentPose())
    print("D2 navigation: departure=\(departure.yaw)°, final=\(finalPose.yaw)°, seconds=\(arrival.durationSeconds), effective=\(abs(finalPose.yaw - departure.yaw) / arrival.durationSeconds)°/s")
    let constant = DUMLFrame(sender: 4, receiver: 2, sequence: 1, commandType: 0,
        commandSet: 0x04, command: 0x57, payload: [0, 0, 0])
    for index in 0..<3 {
        let event = DUMLParseResult(rawBytes: constant.encoded(), frame: constant, crcValid: true)
        await buffer.append(LabFrameEvent(result: event, receivedAt: clock.now().addingTimeInterval(Double(index) / 10)))
    }
    #expect(await runner.run(.constantTelemetry).status == .passed)
    let immobileSim = SimGimbal()
    let immobile = ImmobilePoseFeedbackDevice(simulator: immobileSim, clock: clock)
    let deadController = GimbalController(device: immobile, policy: policy, now: { clock.now() })
    let deadRunner = LabHardwareTestRunner(transport: link, device: immobile, controller: deadController,
        navigator: GotoNavigator(controller: deadController, clock: liveClock), store: store, frames: buffer,
        battery: { LabBattery(percent: 25, charging: false) }, clock: liveClock)
    #expect(await deadRunner.run(.yawMovement).status == .failed)
    let drifting = DriftingPoseFeedbackDevice(clock: clock)
    let driftController = GimbalController(device: drifting, policy: policy, now: { clock.now() })
    let driftRunner = LabHardwareTestRunner(transport: link, device: drifting, controller: driftController,
        navigator: GotoNavigator(controller: driftController, clock: liveClock), store: store, frames: buffer,
        battery: { LabBattery(percent: 25, charging: false) }, clock: liveClock)
    #expect(await driftRunner.run(.restStability).status == .failed)
    let noBatteryRunner = LabHardwareTestRunner(transport: link, device: device, controller: controller,
        navigator: GotoNavigator(controller: controller, clock: liveClock), store: store, frames: buffer,
        battery: { nil }, clock: liveClock)
    #expect(await noBatteryRunner.run(.battery).status == .failed)
    let noStop = NonStoppingPoseFeedbackDevice(clock: clock)
    let noStopController = GimbalController(device: noStop, policy: policy, now: { clock.now() })
    let noStopRunner = LabHardwareTestRunner(transport: link, device: noStop, controller: noStopController,
        navigator: GotoNavigator(controller: noStopController, clock: liveClock), store: store, frames: buffer,
        battery: { LabBattery(percent: 25, charging: false) }, clock: liveClock)
    #expect(await noStopRunner.run(.stop).status == .failed)
    let frozen = FrozenPoseFeedbackDevice(pose: Pose(), clock: clock)
    let frozenController = GimbalController(device: frozen, policy: policy, now: { clock.now() })
    let emptyBuffer = LabFrameBuffer()
    let frozenRunner = LabHardwareTestRunner(transport: link, device: frozen, controller: frozenController,
        navigator: GotoNavigator(controller: frozenController, clock: liveClock), store: store, frames: emptyBuffer,
        battery: { LabBattery(percent: 25, charging: false) }, clock: liveClock)
    #expect(await frozenRunner.run(.connectionTelemetry).status == .failed)
    #expect(await frozenRunner.run(.constantTelemetry).status == .failed)
    await frozenRunner.setReferenceConfirmed(true)
    let frozenZoneRunner = LabHardwareTestRunner(transport: link, device: frozen, controller: frozenController,
        navigator: GotoNavigator(controller: frozenController, clock: liveClock), store: store, frames: emptyBuffer,
        battery: { LabBattery(percent: 25, charging: false) }, clock: observingClock)
    await frozenZoneRunner.setReferenceConfirmed(true)
    #expect(await frozenZoneRunner.run(.zoneGoto).status == .failed)

    let lagged = LaggedPoseDevice(clock: clock)
    let laggedClock = RuntimeClock(now: { clock.now() }, sleep: { seconds in
        try Task.checkCancellation()
        if seconds > 0.3 { try await sleeper.sleep(seconds); return }
        await lagged.advance(seconds)
        await sleeper.timeAdvanced()
        await Task.yield()
    })
    let laggedController = GimbalController(device: lagged, policy: policy, now: { clock.now() })
    let laggedRunner = LabHardwareTestRunner(transport: link, device: lagged, controller: laggedController,
        navigator: GotoNavigator(controller: laggedController, clock: laggedClock), store: store, frames: buffer,
        battery: { LabBattery(percent: 25, charging: false) }, clock: observingClock)
    await laggedRunner.setReferenceConfirmed(true)
    #expect(await laggedRunner.run(.zoneGoto).status == .passed)
    let runaway = RunawayPoseFeedbackDevice(clock: clock)
    let runawayController = GimbalController(device: runaway, policy: policy, now: { clock.now() })
    let runawayRunner = LabHardwareTestRunner(transport: link, device: runaway, controller: runawayController,
        navigator: GotoNavigator(controller: runawayController, clock: liveClock), store: store, frames: buffer,
        battery: { LabBattery(percent: 25, charging: false) }, clock: liveClock)
    let aborted = await runawayRunner.run(.restStability)
    #expect(aborted.status == .failed && aborted.summary.contains(">45°"))
    #expect(await runaway.stopCount() > 0)
}

/// Observes manual time without advancing it. Cancellation closes AsyncStream waits.
private actor LabTestSleeper {
    let clock: ManualClock
    private var waiters: [UUID: (deadline: Date, seconds: Double, continuation: AsyncStream<Void>.Continuation)] = [:]
    init(clock: ManualClock) { self.clock = clock }
    func hasWaiter(for seconds: Double) -> Bool { waiters.values.contains { $0.seconds == seconds } }
    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let pair = AsyncStream.makeStream(of: Void.self)
        waiters[id] = (clock.now().addingTimeInterval(seconds), seconds, pair.continuation)
        defer { waiters.removeValue(forKey: id) }
        for await _ in pair.stream { break }
        try Task.checkCancellation()
    }
    func timeAdvanced() {
        for waiter in waiters.values where clock.now() >= waiter.deadline {
            waiter.continuation.yield(())
            waiter.continuation.finish()
        }
    }
}

@Test(arguments: [false, true])
func hardwareZoneGotoSkipsMissingOrDistantZones(distant: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = ManualClock()
    let simulator = SimGimbal()
    let device = SimPoseFeedbackDevice(simulator: simulator, clock: clock)
    // The nearest permitted center is 21° away; a forbidden center is nearer.
    let zones = distant ? [Zone(name: "lejana", yaw: -10...52, pitch: -20...20),
                           Zone(name: "aún más lejos", yaw: -10...70, pitch: -20...20),
                           Zone(name: "prohibida", yaw: -10...10, pitch: -10...10, forbidden: true)] : []
    let store = ZoneStore(url: directory.appendingPathComponent("zones.json"))
    try await store.save(zones)
    let controller = GimbalController(device: device,
        policy: SafetyPolicy(maxSpeed: 12, maxLeaseSeconds: 30, deadmanSeconds: 1, zones: zones), now: { clock.now() })
    let timing = RuntimeClock(now: { clock.now() }, sleep: { seconds in await device.advance(seconds) })
    let runner = LabHardwareTestRunner(transport: FakeLabLink(), device: device, controller: controller,
        navigator: GotoNavigator(controller: controller, clock: timing), store: store, frames: LabFrameBuffer(),
        battery: { nil }, clock: timing)
    await runner.setReferenceConfirmed(true)
    let result = await runner.run(.zoneGoto)
    #expect(result.status == .skipped)
    #expect(result.statusText == "SALTADA")
    #expect(result.summary == (distant
        ? "zona demasiado lejos: el navegador avanza ~1,2 °/s y el plazo es de 25 s; acerca la Osmo o guarda una zona a ≤ 20°"
        : "no hay zonas guardadas"))
    #expect(await controller.activeLease == nil)
    #expect(await simulator.commands.allSatisfy { $0 == .stop })
    let report = LabReport.markdown(results: [result], date: clock.now())
    #expect(report.contains("**SALTADA**"))
    #expect(!report.contains("**FALLA**"))
}

@Test func skippedHardwareTestsDoNotIncreaseReportFailureCount() {
    let results = [
        LabTestResult(kind: .battery, status: .passed, summary: "OK", measurements: [:], durationSeconds: 0),
        LabTestResult(kind: .stop, status: .failed, summary: "STOP", measurements: [:], durationSeconds: 0),
        LabTestResult(kind: .zoneGoto, status: .skipped, summary: "no hay zonas guardadas", measurements: [:], durationSeconds: 0)
    ]
    let report = LabReport.markdown(results: results, date: Date(timeIntervalSince1970: 0))
    #expect(report.contains("PASA: 1 · FALLA: 1 · SALTADA: 1"))
}

@Test func hardwareZoneGotoSelectsNearestPermittedCenter() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = ManualClock()
    let simulator = SimGimbal()
    let device = SimPoseFeedbackDevice(simulator: simulator, clock: clock)
    let zones = [Zone(name: "lejana", yaw: -10...70, pitch: -20...20),
                 Zone(name: "prohibida", yaw: -10...10, pitch: -10...10, forbidden: true),
                 Zone(name: "cercana", yaw: -20...20, pitch: -20...20)]
    let store = ZoneStore(url: directory.appendingPathComponent("zones.json"))
    try await store.save(zones)
    let controller = GimbalController(device: device,
        policy: SafetyPolicy(maxSpeed: 12, maxLeaseSeconds: 30, deadmanSeconds: 1, zones: zones), now: { clock.now() })
    let sleeper = LabTestSleeper(clock: clock)
    let navigationClock = RuntimeClock(now: { clock.now() }, sleep: { seconds in
        try Task.checkCancellation()
        if seconds > 0.3 { try await sleeper.sleep(seconds); return }
        await device.advance(seconds)
        await sleeper.timeAdvanced()
        await Task.yield()
    })
    let observingClock = RuntimeClock(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    let runner = LabHardwareTestRunner(transport: FakeLabLink(), device: device, controller: controller,
        navigator: GotoNavigator(controller: controller, clock: navigationClock), store: store, frames: LabFrameBuffer(),
        battery: { nil }, clock: observingClock)
    await runner.setReferenceConfirmed(true)
    let result = await runner.run(.zoneGoto)
    #expect(result.status == .passed)
    #expect(result.measurements["center_error_degrees"] == 0)
    #expect(await controller.activeLease == nil)
    #expect(await simulator.commands.allSatisfy { $0 == .stop })
}
