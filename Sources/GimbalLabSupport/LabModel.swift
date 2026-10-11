import Foundation
import Observation
import GimbalKit
import GimbalKitDJI

public enum LabBluetoothAuthorization: Sendable, Equatable { case notDetermined, allowed, denied, restricted, unavailable }
public enum LabConnection: Sendable, Equatable { case disconnected, connecting, connected }
public protocol LabLink: OMTransport {
    var bluetoothAuthorization: LabBluetoothAuthorization { get }
    var disconnects: AsyncStream<Void> { get }
    func connect() async throws
    func disconnect() async
}
public struct LabBattery: Sendable, Equatable {
    public let percent: Int
    public let charging: Bool
    public init(percent: Int, charging: Bool) { self.percent = percent; self.charging = charging }
}
public struct LabFrameEvent: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let receivedAt: Date
    public let commandSet: UInt8?
    public let command: UInt8?
    public let payload: [UInt8]?
    public let crcValid: Bool
    public let hex: String
    public init(result: DUMLParseResult, receivedAt: Date) {
        id = UUID(); self.receivedAt = receivedAt
        commandSet = result.commandSet; command = result.command
        payload = result.frame?.payload; crcValid = result.crcValid
        hex = result.rawBytes.map { String(format: "%02x", $0) }.joined()
    }
}
public struct LabPosePoint: Sendable, Identifiable {
    public let id: UInt64
    public let date: Date
    public let pose: Pose
    public init(id: UInt64, date: Date, pose: Pose) { self.id = id; self.date = date; self.pose = pose }
}
public enum LabAxis: Sendable, Equatable { case yaw, pitch }

public actor LabFrameBuffer {
    private var rows: [LabFrameEvent] = []
    private var valid = 0
    private var invalid = 0
    public init() {}
    public func append(_ frame: LabFrameEvent) {
        if frame.crcValid { valid += 1 } else { invalid += 1 }
        rows.append(frame)
        if rows.count > 2048 { rows.removeFirst(rows.count - 2048) }
    }
    public func snapshot() -> (rows: [LabFrameEvent], valid: Int, invalid: Int) { (rows, valid, invalid) }
    public func constantTelemetry() -> [LabFrameEvent] {
        rows.filter { $0.crcValid && $0.commandSet == 0x04 && $0.command == 0x57 }
    }
}

public final class LabObservedTransport: OMTransport, @unchecked Sendable {
    public let notifications: AsyncStream<[UInt8]>
    public let frameEvents: AsyncStream<LabFrameEvent>
    private let base: any OMTransport
    private let pump: Task<Void, Never>
    public init(base: any OMTransport, now: @escaping @Sendable () -> Date) {
        self.base = base
        let n = AsyncStream.makeStream(of: [UInt8].self)
        let f = AsyncStream.makeStream(of: LabFrameEvent.self)
        notifications = n.stream; frameEvents = f.stream
        pump = Task {
            var parser = DUMLParser()
            for await chunk in base.notifications {
                guard !Task.isCancelled else { break }
                n.continuation.yield(chunk)
                for result in parser.feedEvents(chunk) { f.continuation.yield(LabFrameEvent(result: result, receivedAt: now())) }
            }
            n.continuation.finish(); f.continuation.finish()
        }
    }
    public func write(_ bytes: [UInt8]) async throws { try await base.write(bytes) }
    deinit { pump.cancel() }
}

public actor LabRecordingDevice: PoseFeedbackDevice {
    public nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback, .battery]
    private let device: OMDevice
    private let recorder: LabSessionRecorder
    public init(device: OMDevice, recorder: LabSessionRecorder) { self.device = device; self.recorder = recorder }
    public func currentPose() async -> Pose? { await device.currentPose() }
    public func poseSample() async -> PoseSample? { await device.poseSample() }
    public func send(_ command: MoveCommand) async throws {
        try await device.send(command)
        switch command {
        case let .speed(yaw, pitch, roll): try await recorder.recordTX(yaw: yaw, pitch: pitch, roll: roll)
        case .stop: try await recorder.recordTX(yaw: 0, pitch: 0, roll: 0)
        case .absolute: break
        }
    }
}

@MainActor @Observable public final class LabModel {
    public private(set) var authorization: LabBluetoothAuthorization = .notDetermined
    public private(set) var connection: LabConnection = .disconnected
    public private(set) var errorMessage: String?
    public private(set) var pose: Pose?
    public private(set) var poseAgeSeconds: Double?
    public private(set) var updateHz = 0.0
    public private(set) var battery: LabBattery?
    public private(set) var poseHistory: [LabPosePoint] = []
    public private(set) var zones: [Zone] = []
    public private(set) var referenceConfirmed = false
    public private(set) var frames: [LabFrameEvent] = []
    public private(set) var validFrameCount = 0
    public private(set) var invalidFrameCount = 0
    public private(set) var testResults: [LabTestResult] = []
    public var commandSetFilter = ""
    public var commandFilter = ""
    public var isFrameListPaused = false
    public var phase = "pre"
    @ObservationIgnored private let store: ZoneStore
    @ObservationIgnored private let clock: RuntimeClock
    @ObservationIgnored private let frameBuffer = LabFrameBuffer()
    @ObservationIgnored private var link: (any LabLink)?
    @ObservationIgnored private var transport: LabObservedTransport?
    @ObservationIgnored private var device: OMDevice?
    @ObservationIgnored private var recordingDevice: LabRecordingDevice?
    @ObservationIgnored private var recorder = LabSessionRecorder()
    @ObservationIgnored private var controller: GimbalController?
    @ObservationIgnored private var navigator: GotoNavigator?
    @ObservationIgnored private var runner: LabHardwareTestRunner?
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var disconnectTask: Task<Void, Never>?
    @ObservationIgnored private var manualTask: Task<Void, Never>?
    @ObservationIgnored private var testTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var poseDates: [Date] = []
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var session = UUID()

    public init(store: ZoneStore, clock: RuntimeClock = .live) { self.store = store; self.clock = clock }
    public var authorizationText: String {
        switch authorization {
        case .notDetermined: "Sin decidir"
        case .allowed: "Permitido"
        case .denied: "Denegado"
        case .restricted: "Restringido"
        case .unavailable: "No disponible"
        }
    }
    public var connectionText: String {
        switch connection {
        case .disconnected: "Desconectado"
        case .connecting: "Conectando"
        case .connected: "Conectado"
        }
    }
    public var firstAllowedZoneName: String? { zones.first(where: { !$0.forbidden })?.name }
    public var visibleFrames: [LabFrameEvent] {
        let set = commandSetFilter.isEmpty ? nil : UInt8(commandSetFilter, radix: 16)
        let command = commandFilter.isEmpty ? nil : UInt8(commandFilter, radix: 16)
        if !commandSetFilter.isEmpty && set == nil { return [] }
        if !commandFilter.isEmpty && command == nil { return [] }
        return frames.filter { frame in
            return (commandSetFilter.isEmpty || frame.commandSet == set) && (commandFilter.isEmpty || frame.command == command)
        }
    }

    public func connect(using newLink: any LabLink) async {
        guard connection == .disconnected else { return }
        let id = UUID(); session = id; link = newLink
        authorization = newLink.bluetoothAuthorization; connection = .connecting; errorMessage = nil
        do {
            zones = try await store.load()
            try await newLink.connect()
            guard session == id else { await newLink.disconnect(); return }
            let observed = LabObservedTransport(base: newLink, now: clock.now)
            let device = OMDevice(transport: observed, now: clock.now)
            let recorded = LabRecordingDevice(device: device, recorder: recorder)
            let controller = GimbalController(device: recorded,
                policy: SafetyPolicy(maxSpeed: 12, maxLeaseSeconds: 30, deadmanSeconds: 0.75, zones: zones), now: clock.now)
            let navigator = GotoNavigator(controller: controller, clock: clock)
            self.transport = observed; self.device = device; self.controller = controller
            self.navigator = navigator; recordingDevice = recorded
            runner = LabHardwareTestRunner(transport: observed, device: recorded, controller: controller,
                navigator: navigator, store: store, frames: frameBuffer,
                battery: { await device.battery.map { LabBattery(percent: $0.percent, charging: $0.charging) } }, clock: clock)
            await runner?.setReferenceConfirmed(zones.isEmpty)
            await device.start(); connection = .connected; referenceConfirmed = zones.isEmpty
            frameTask = Task { [weak self, stream = observed.frameEvents] in
                for await frame in stream {
                    guard !Task.isCancelled else { break }
                    await self?.receive(frame)
                }
            }
            refreshTask = Task { [weak self, clock] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do { try await clock.sleep(0.1) } catch { break }
                }
            }
            disconnectTask = Task { [weak self, stream = newLink.disconnects] in
                for await _ in stream { await self?.connectionLost(id); break }
            }
        } catch {
            if session == id {
                authorization = newLink.bluetoothAuthorization
                connection = .disconnected; errorMessage = String(describing: error); self.link = nil
            }
            await newLink.disconnect()
        }
    }
    public func reconnect(makeLink: @Sendable () -> any LabLink) async {
        await disconnect(); await connect(using: makeLink())
    }
    public func disconnect() async {
        let old = link
        await stopAll()
        session = UUID()
        frameTask?.cancel(); refreshTask?.cancel(); disconnectTask?.cancel()
        frameTask = nil; refreshTask = nil; disconnectTask = nil
        if let device { await device.shutdown() }
        try? await recorder.stop()
        await old?.disconnect()
        link = nil; transport = nil; device = nil; recordingDevice = nil; controller = nil; navigator = nil; runner = nil
        connection = .disconnected; pose = nil; poseAgeSeconds = nil; battery = nil; referenceConfirmed = false
    }
    private func connectionLost(_ id: UUID) async {
        guard session == id else { return }
        session = UUID(); frameTask?.cancel(); refreshTask?.cancel()
        manualTask?.cancel(); manualTask = nil; testTask?.cancel(); testTask = nil
        navigationTask?.cancel(); navigationTask = nil
        if let controller { await controller.deviceDisconnected() }
        if let device { await device.shutdown() }
        try? await recorder.stop()
        await link?.disconnect()
        link = nil; transport = nil; device = nil; recordingDevice = nil; controller = nil; navigator = nil; runner = nil
        connection = .disconnected; pose = nil; poseAgeSeconds = nil; battery = nil; referenceConfirmed = false
    }
    public func refresh() async {
        if let link { authorization = link.bluetoothAuthorization }
        await controller?.tick()
        guard let device else { return }
        if let sample = await device.poseSample() {
            let age = clock.now().timeIntervalSince(sample.receivedAt)
            poseAgeSeconds = age >= 0 ? age : nil
            pose = age >= 0 && age <= 1.5 ? sample.pose : nil
            if sample.sequence != lastSequence {
                lastSequence = sample.sequence; poseDates.append(sample.receivedAt)
                if poseDates.count > 20 { poseDates.removeFirst(poseDates.count - 20) }
                if poseDates.count > 1, let first = poseDates.first, let last = poseDates.last {
                    let span = last.timeIntervalSince(first)
                    updateHz = span > 0 ? Double(poseDates.count - 1) / span : 0
                }
                poseHistory.append(LabPosePoint(id: sample.sequence, date: sample.receivedAt, pose: sample.pose))
                poseHistory.removeAll { $0.date < clock.now().addingTimeInterval(-30) }
            }
        }
        if let value = await device.battery { battery = LabBattery(percent: value.percent, charging: value.charging) }
    }
    private func receive(_ frame: LabFrameEvent) async {
        await frameBuffer.append(frame)
        let snapshot = await frameBuffer.snapshot()
        validFrameCount = snapshot.valid; invalidFrameCount = snapshot.invalid
        if !isFrameListPaused { frames = snapshot.rows }
        do { try await recorder.recordRX(hex: frame.hex, crc: frame.crcValid) }
        catch { errorMessage = "No se pudo escribir la captura JSONL: \(error)" }
    }
    public func setPhase(_ value: String) async { phase = value; await recorder.setPhase(value) }
    public func presentError(_ message: String) { errorMessage = message }
    public func startRecording(at url: URL) async throws { try await recorder.start(at: url); await recorder.setPhase(phase) }
    public func stopRecording() async { try? await recorder.stop() }
    public func confirmReference() async {
        referenceConfirmed = true
        await runner?.setReferenceConfirmed(true)
    }
    public func startManual(axis: LabAxis, direction: Int, speed: Double) {
        guard let controller, connection == .connected, speed.isFinite, (0...12).contains(speed), abs(direction) == 1 else { return }
        manualTask?.cancel()
        manualTask = Task { [clock] in
            do {
                while !Task.isCancelled {
                    let value = speed * Double(direction)
                    try await controller.send(axis == .yaw ? .speed(yaw: value, pitch: 0, roll: 0) : .speed(yaw: 0, pitch: value, roll: 0), source: .app)
                    try await clock.sleep(0.30)
                }
            } catch is CancellationError { }
            catch {
                await controller.stop(source: .app)
                await MainActor.run { self.presentError(String(describing: error)) }
            }
        }
    }
    public func endManual() async {
        manualTask?.cancel(); manualTask = nil
        await controller?.stop(source: .app)
    }
    public func go(to zoneName: String?) async {
        guard referenceConfirmed, let zoneName, let controller, let navigator else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performNavigation(to: zoneName, controller: controller, navigator: navigator)
        }
        navigationTask = task
        await task.value
        navigationTask = nil
    }
    private func performNavigation(to zoneName: String, controller: GimbalController, navigator: GotoNavigator) async {
        do {
            let lease = try await controller.requestLease(source: .app, zone: zoneName, seconds: 30)
            do { _ = try await navigator.go(to: zoneName, source: .app, lease: lease); await controller.release(lease: lease) }
            catch { await controller.release(lease: lease); throw error }
        } catch { errorMessage = String(describing: error) }
    }
    public func runAllTests() async {
        guard let runner else { return }
        testResults = []
        let task = Task<Void, Never> { @MainActor [weak self] in
            for kind in LabTestKind.allCases {
                guard !Task.isCancelled, let self else { return }
                self.testResults.append(await runner.run(kind))
            }
        }
        testTask = task
        await task.value
        testTask = nil
    }
    public func stopAll() async {
        manualTask?.cancel(); manualTask = nil; testTask?.cancel(); testTask = nil
        navigationTask?.cancel(); navigationTask = nil
        if let runner { await runner.stopAll() } else { await controller?.stop(source: .app) }
    }
    public func exportReport(to url: URL) throws {
        try LabReport.markdown(results: testResults, date: clock.now()).write(to: url, atomically: true, encoding: .utf8)
    }
}
