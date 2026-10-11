import Foundation
import Testing
import GimbalKit
import GimbalKitDJI
import GimbalKitSim
@testable import GimbalLabSupport

@Test func autoRunArgumentsRequireExplicitFlag() throws {
    #expect(try LabAutoRunOptions.parse([]) == nil)
    #expect(try LabAutoRunOptions.parse(["--out", "ignored.md", "--solo", "yaw"]) == nil)
    let all = try #require(try LabAutoRunOptions.parse(["--auto-run", "--out", "report.md"]))
    #expect(all.tests == LabTestKind.allCases)
    #expect(all.outputURL.lastPathComponent == "report.md")
    let selected = try #require(try LabAutoRunOptions.parse([
        "--auto-run", "--solo", "yaw,reposo,bateria,parada,telemetria", "--out", "report.md"
    ]))
    #expect(selected.tests == [.yawMovement, .restStability, .battery, .stop, .constantTelemetry])
}

@Test(arguments: [
    ["--auto-run"], ["--auto-run", "--out"], ["--auto-run", "--out", ""],
    ["--auto-run", "--out", "a.md", "--solo", ""],
    ["--auto-run", "--out", "a.md", "--solo", "yaw,unknown"],
    ["--auto-run", "--out", "a.md", "--solo", "yaw,,parada"],
    ["--auto-run", "--out", "a.md", "--out", "b.md"],
    ["--auto-run", "--out", "a.md", "--unknown"]
])
func autoRunRejectsMalformedArguments(arguments: [String]) {
    #expect(throws: LabAutoRunArgumentError.self) { try LabAutoRunOptions.parse(arguments) }
}

private actor AutoLink: LabLink {
    enum Mode: Sendable { case connected, failed, pending }
    nonisolated let bluetoothAuthorization: LabBluetoothAuthorization = .allowed
    nonisolated let notifications: AsyncStream<[UInt8]>
    private let notificationContinuation: AsyncStream<[UInt8]>.Continuation
    nonisolated let disconnects = AsyncStream<Void> { _ in }
    let mode: Mode
    let initialFrames: [[UInt8]]
    private(set) var connects = 0
    private(set) var disconnectCount = 0
    private(set) var writes: [[UInt8]] = []
    init(_ mode: Mode = .connected, initialFrames: [[UInt8]] = []) {
        self.mode = mode; self.initialFrames = initialFrames
        let pair = AsyncStream.makeStream(of: [UInt8].self)
        notifications = pair.stream; notificationContinuation = pair.continuation
    }
    func connect() async throws {
        connects += 1
        switch mode {
        case .connected:
            for frame in initialFrames { notificationContinuation.yield(frame) }
        case .failed: throw AutoFailure()
        case .pending:
            for await _ in AsyncStream<Void>(Void.self, bufferingPolicy: .unbounded, { _ in }) { }
            try Task.checkCancellation()
        }
    }
    func disconnect() { disconnectCount += 1; notificationContinuation.finish() }
    func write(_ bytes: [UInt8]) { writes.append(bytes) }
}
private struct AutoFailure: Error {}

private actor AutoPoseDevice: PoseFeedbackDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback, .battery]
    let simulator: SimGimbal
    let clock: ManualClock
    let wire: OMDevice
    init(simulator: SimGimbal, clock: ManualClock, link: AutoLink) {
        self.simulator = simulator; self.clock = clock; wire = OMDevice(transport: link)
    }
    func send(_ command: MoveCommand) async throws {
        try await simulator.send(command)
        try await wire.send(command)
    }
    func currentPose() async -> Pose? { await simulator.currentPose() }
    func poseSample() async -> PoseSample? {
        PoseSample(pose: await simulator.currentPose() ?? Pose(), receivedAt: clock.now(), sequence: 1)
    }
    func advance(_ seconds: Double) async { await simulator.advance(seconds: seconds); clock.advance(seconds) }
}

private final class AutoLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = [] // All access is protected by lock.
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func snapshot() -> [String] { lock.withLock { lines } }
}

@Test(arguments: [false, true])
func autoRunWritesReportAndStopsAfterPassOrFailure(failure: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let out = directory.appendingPathComponent("nested/report.md")
    let options = try #require(try LabAutoRunOptions.parse(["--auto-run", "--out", out.path, "--solo", "yaw,bateria"]))
    let clock = ManualClock()
    let sim = SimGimbal()
    let link = AutoLink()
    let device = AutoPoseDevice(simulator: sim, clock: clock, link: link)
    let timing = RuntimeClock(now: { clock.now() }, sleep: { seconds in
        if seconds >= 20 {
            for await _ in AsyncStream<Void>(Void.self, bufferingPolicy: .unbounded, { _ in }) { }
            try Task.checkCancellation()
        } else { try Task.checkCancellation(); await device.advance(seconds) }
    })
    let log = AutoLog()
    let session = LabAutoRunSession(link: link, store: ZoneStore(url: directory.appendingPathComponent("zones.json")),
        device: device, battery: { failure ? nil : LabBattery(percent: 25, charging: false) },
        clock: timing, output: { log.append($0) })
    #expect(await session.run(options) == (failure ? 1 : 0))
    let report = try String(contentsOf: out, encoding: .utf8)
    #expect(report.contains(failure ? "FALLA: 1" : "FALLA: 0"))
    #expect(report.contains("outbound_degrees"))
    #expect(await sim.commands.last == .stop)
    let stop = OMRotate(yaw: 0, pitch: 0, roll: 0, time: 10, mode: .speed).frame().encoded()
    #expect(await link.writes.last == stop)
    #expect(await link.disconnectCount == 1)
    #expect(log.snapshot().allSatisfy { $0.hasPrefix("LAB ") })
    #expect(log.snapshot().contains { $0.contains("PASA") && $0.contains("outbound_degrees") })
    #expect(await sim.commands.allSatisfy {
        if case let .speed(yaw, pitch, roll) = $0 { return max(abs(yaw), abs(pitch), abs(roll)) <= 12 }
        return $0 == .stop
    })
}

@Test(arguments: [false, true])
func autoRunConnectionFailureOrDeadlineReturnsTwo(timeout: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let out = directory.appendingPathComponent("report.md")
    let options = try #require(try LabAutoRunOptions.parse(["--auto-run", "--out", out.path]))
    let clock = ManualClock(Date(timeIntervalSince1970: 0))
    let link = AutoLink(timeout ? .pending : .failed)
    let timing = RuntimeClock(now: { clock.now() }, sleep: { seconds in
        if timeout { clock.advance(seconds) }
        else {
            for await _ in AsyncStream<Void>(Void.self, bufferingPolicy: .unbounded, { _ in }) { }
            try Task.checkCancellation()
        }
    })
    let session = LabAutoRunSession(link: link, store: ZoneStore(url: directory.appendingPathComponent("zones.json")),
        clock: timing, output: { _ in })
    #expect(await session.run(options) == 2)
    #expect(try String(contentsOf: out, encoding: .utf8).contains("Conexión"))
    let stop = OMRotate(yaw: 0, pitch: 0, roll: 0, time: 10, mode: .speed).frame().encoded()
    #expect(await link.writes.last == stop)
    #expect(await link.disconnectCount == 1)
    if timeout { #expect(clock.now().timeIntervalSince(Date(timeIntervalSince1970: 0)) >= 20) }
}

@Test func autoRunWithoutFlagDoesNotConnectWriteOrCreateReport() async throws {
    let link = AutoLink()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session = LabAutoRunSession(link: link, store: ZoneStore(url: directory.appendingPathComponent("zones.json")), output: { _ in })
    #expect(await session.run(try LabAutoRunOptions.parse([])) == nil)
    #expect(await link.connects == 0)
    #expect(await link.writes.isEmpty)
    #expect(await link.disconnectCount == 0)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func autoRunRealDevicePipelineReadsFakeBluetoothFrames() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let out = directory.appendingPathComponent("report.md")
    let options = try #require(try LabAutoRunOptions.parse(["--auto-run", "--out", out.path, "--solo", "bateria"]))
    let link = AutoLink(initialFrames: [realBytes(Real.yawA), realBytes(Real.battery)])
    let session = LabAutoRunSession(link: link, store: ZoneStore(url: directory.appendingPathComponent("zones.json")), output: { _ in })
    #expect(await session.run(options) == 0)
    #expect(try String(contentsOf: out, encoding: .utf8).contains("percent: 25.0"))
    let stop = OMRotate(yaw: 0, pitch: 0, roll: 0, time: 10, mode: .speed).frame().encoded()
    #expect(await link.writes.last == stop)
}

@Test(arguments: [false, true])
func autoRunCancellationStopsAndReportsDuringConnectionOrMovement(moving: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let out = directory.appendingPathComponent("report.md")
    let options = try #require(try LabAutoRunOptions.parse(["--auto-run", "--out", out.path, "--solo", "yaw"]))
    let link = AutoLink(moving ? .connected : .pending)
    let clock = ManualClock()
    let sim = SimGimbal()
    let device = AutoPoseDevice(simulator: sim, clock: clock, link: link)
    let timing = RuntimeClock(now: { clock.now() }, sleep: { _ in
        for await _ in AsyncStream<Void>(Void.self, bufferingPolicy: .unbounded, { _ in }) { }
        try Task.checkCancellation()
    })
    let session = LabAutoRunSession(link: link, store: ZoneStore(url: directory.appendingPathComponent("zones.json")),
        device: device, clock: timing, output: { _ in })
    let task = Task { await session.run(options) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var ready = false
    while ContinuousClock.now < deadline {
        if moving {
            ready = await sim.commands.contains(.speed(yaw: 10, pitch: 0, roll: 0))
        } else { ready = await link.connects == 1 }
        if ready { break }
        await Task.yield()
    }
    #expect(ready)
    task.cancel()
    #expect(await task.value == 1)
    #expect(await sim.commands.last == .stop)
    #expect(await link.disconnectCount == 1)
    #expect(try String(contentsOf: out, encoding: .utf8).contains("FALLA"))
}

@Test func autoRunReportWriteErrorStillStopsAndReturnsOne() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let parentFile = directory.appendingPathComponent("file")
    try Data().write(to: parentFile)
    let out = parentFile.appendingPathComponent("report.md")
    let options = try #require(try LabAutoRunOptions.parse(["--auto-run", "--out", out.path, "--solo", "bateria"]))
    let link = AutoLink()
    let clock = ManualClock()
    let sim = SimGimbal()
    let device = AutoPoseDevice(simulator: sim, clock: clock, link: link)
    let timing = RuntimeClock(now: { clock.now() }, sleep: { _ in
        for await _ in AsyncStream<Void>(Void.self, bufferingPolicy: .unbounded, { _ in }) { }
        try Task.checkCancellation()
    })
    let session = LabAutoRunSession(link: link, store: ZoneStore(url: directory.appendingPathComponent("zones.json")),
        device: device, battery: { LabBattery(percent: 25, charging: false) }, clock: timing, output: { _ in })
    #expect(await session.run(options) == 1)
    #expect(await sim.commands.last == .stop)
    #expect(await link.disconnectCount == 1)
}

@Test(arguments: [false, true])
func autoRunZoneRemainsSkippedWithoutConfirmedReference(hasZone: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let out = directory.appendingPathComponent("report.md")
    let options = LabAutoRunOptions(outputURL: out, tests: [.zoneGoto])
    let store = ZoneStore(url: directory.appendingPathComponent("zones.json"))
    if hasZone { try await store.save([Zone(name: "cercana", yaw: -20...20, pitch: -20...20)]) }
    let link = AutoLink()
    let clock = ManualClock()
    let sim = SimGimbal()
    let device = AutoPoseDevice(simulator: sim, clock: clock, link: link)
    let timing = RuntimeClock(now: { clock.now() }, sleep: { _ in
        for await _ in AsyncStream<Void>(Void.self, bufferingPolicy: .unbounded, { _ in }) { }
        try Task.checkCancellation()
    })
    let session = LabAutoRunSession(link: link, store: store, device: device, clock: timing, output: { _ in })
    #expect(await session.run(options) == 0)
    let report = try String(contentsOf: out, encoding: .utf8)
    #expect(report.contains("SALTADA: 1"))
    #expect(report.contains(hasZone ? "Referencia humana sin confirmar" : "no hay zonas guardadas"))
    #expect(await sim.commands.allSatisfy { $0 == .stop })
}
