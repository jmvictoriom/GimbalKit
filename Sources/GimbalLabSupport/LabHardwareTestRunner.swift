import Foundation
import GimbalKit
import GimbalKitDJI

public enum LabTestKind: String, CaseIterable, Sendable, Equatable {
    case connectionTelemetry, restStability, battery, yawMovement, stop, zoneGoto, constantTelemetry
}
public enum LabTestStatus: String, Sendable, Equatable { case passed, failed, skipped }
public struct LabTestResult: Sendable, Identifiable {
    public let id: UUID
    public let kind: LabTestKind
    public let status: LabTestStatus
    public let summary: String
    public let measurements: [String: Double]
    public let durationSeconds: Double
    public var name: String {
        switch kind {
        case .connectionTelemetry: "Conexión y telemetría viva"
        case .restStability: "Reposo estable"
        case .battery: "Batería plausible"
        case .yawMovement: "Movimiento y retorno de yaw"
        case .stop: "Parada"
        case .zoneGoto: "Ir a zona"
        case .constantTelemetry: "Telemetría constante 0x04/0x57"
        }
    }
    public var statusText: String { status == .passed ? "PASA" : status == .failed ? "FALLA" : "SALTADA" }
    public init(kind: LabTestKind, status: LabTestStatus, summary: String, measurements: [String: Double], durationSeconds: Double) {
        id = UUID(); self.kind = kind; self.status = status; self.summary = summary
        self.measurements = measurements; self.durationSeconds = durationSeconds
    }
}

public actor LabHardwareTestRunner {
    private let transport: any OMTransport
    private let device: any PoseFeedbackDevice
    private let controller: GimbalController
    private let navigator: GotoNavigator
    private let store: ZoneStore
    private let frames: LabFrameBuffer
    private let battery: @Sendable () async -> LabBattery?
    private let clock: RuntimeClock
    private let limits = NavigationLimits()
    private var running = false
    private var referenceConfirmed = false
    public init(transport: any OMTransport, device: any PoseFeedbackDevice, controller: GimbalController,
                navigator: GotoNavigator, store: ZoneStore, frames: LabFrameBuffer,
                battery: @escaping @Sendable () async -> LabBattery?, clock: RuntimeClock = .live) {
        self.transport = transport; self.device = device; self.controller = controller
        self.navigator = navigator; self.store = store; self.frames = frames; self.battery = battery; self.clock = clock
    }
    public func runAll() async -> [LabTestResult] {
        var results: [LabTestResult] = []
        for kind in LabTestKind.allCases {
            if Task.isCancelled { await controller.stop(source: .app); break }
            results.append(await run(kind))
        }
        return results
    }
    public func run(_ kind: LabTestKind) async -> LabTestResult {
        guard !running else { return result(kind, .failed, "Ya hay una prueba en curso", [:], clock.now()) }
        running = true; defer { running = false }
        let started = clock.now()
        do {
            guard let initial = await device.poseSample(), initial.pose.isFinite,
                  abs(initial.pose.yaw) <= 10, abs(initial.pose.pitch) <= 10 else {
                throw LabTestFailure("La pose inicial debe estar a ≤10° del origen")
            }
            let initialAge = clock.now().timeIntervalSince(initial.receivedAt)
            guard initialAge >= 0, initialAge <= limits.staleSeconds else {
                throw LabTestFailure("La pose inicial está desactualizada", ["pose_age_seconds": initialAge])
            }
            let measurements = try await execute(kind, origin: initial.pose)
            return result(kind, .passed, "Umbral superado", measurements, started)
        } catch {
            await controller.stop(source: .app)
            let status: LabTestStatus = error is LabSkipped ? .skipped : .failed
            let measurements = (error as? LabTestFailure)?.measurements ?? [:]
            return result(kind, status, String(describing: error), measurements, started)
        }
    }
    public func stopAll() async { await controller.stop(source: .app) }
    public func setReferenceConfirmed(_ value: Bool) { referenceConfirmed = value }
    private func execute(_ kind: LabTestKind, origin: Pose) async throws -> [String: Double] {
        switch kind {
        case .connectionTelemetry:
            let first = await device.poseSample()?.sequence ?? 0
            try await wait(5, origin: origin)
            let last = await device.poseSample()?.sequence ?? first
            let hz = Double(last &- first) / 5
            guard hz >= 1 else { throw LabTestFailure("Telemetría <1 Hz", ["hz": hz]) }
            return ["hz": hz]
        case .restStability:
            await controller.stop(source: .app)
            let drift = try await observe(5, measureFrom: origin, safetyOrigin: origin)
            guard drift < 0.2 else { throw LabTestFailure("Deriva ≥0,2°", ["drift_degrees": drift]) }
            return ["drift_degrees": drift]
        case .battery:
            guard let value = await battery() else { throw LabTestFailure("Batería ausente") }
            guard (0...100).contains(value.percent) else { throw LabTestFailure("Batería fuera de 0...100", ["percent": Double(value.percent)]) }
            return ["percent": Double(value.percent), "charging": value.charging ? 1 : 0]
        case .yawMovement:
            try await controller.send(.speed(yaw: 10, pitch: 0, roll: 0), source: .app)
            try await wait(2, origin: origin, refresh: .speed(yaw: 10, pitch: 0, roll: 0)); await controller.stop(source: .app)
            // Asentamiento: la telemetría llega a ~1 Hz y retrasada; leer la pose justo al parar mide un giro a medias.
            try await wait(2, origin: origin)
            let turned = await device.currentPose()?.yaw ?? origin.yaw
            let delta = turned - origin.yaw
            guard (16...24).contains(delta) else { throw LabTestFailure("Yaw +10 ×2s dio \(delta)°; esperado 20° ±4°", ["outbound_degrees": delta]) }
            try await controller.send(.speed(yaw: -10, pitch: 0, roll: 0), source: .app)
            try await wait(2, origin: origin, refresh: .speed(yaw: -10, pitch: 0, roll: 0)); await controller.stop(source: .app)
            // Asentamiento: la telemetría llega a ~1 Hz y retrasada; leer la pose justo al parar mide un giro a medias.
            try await wait(2, origin: origin)
            let returned = await device.currentPose()?.yaw ?? turned
            let error = abs(returned - origin.yaw)
            guard error <= 3 else { throw LabTestFailure("Retorno desviado \(error)°; máximo 3°", ["outbound_degrees": delta, "return_error_degrees": error]) }
            return ["outbound_degrees": delta, "return_error_degrees": error]
        case .stop:
            try await controller.send(.speed(yaw: 6, pitch: 0, roll: 0), source: .app)
            try await wait(1, origin: origin, refresh: .speed(yaw: 6, pitch: 0, roll: 0)); await controller.stop(source: .app)
            // Asentamiento: la telemetría llega a ~1 Hz y retrasada; la referencia se toma cuando ya ha alcanzado el reposo.
            try await wait(2, origin: origin)
            let stopped = await device.currentPose() ?? origin
            let drift = try await observe(2, measureFrom: stopped, safetyOrigin: origin)
            // Tramo de vuelta (sin aserción propia) para dejar la Osmo donde estaba y no acumular desplazamiento entre ejecuciones.
            try await controller.send(.speed(yaw: -6, pitch: 0, roll: 0), source: .app)
            try await wait(1, origin: origin, refresh: .speed(yaw: -6, pitch: 0, roll: 0)); await controller.stop(source: .app)
            try await wait(2, origin: origin)
            guard drift <= 0.3 else { throw LabTestFailure("STOP dejó deriva \(drift)°", ["drift_after_stop_degrees": drift]) }
            return ["drift_after_stop_degrees": drift]
        case .zoneGoto:
            let zones = try await store.load()
            guard !zones.isEmpty else { throw LabSkipped("no hay zonas guardadas") }
            // Use the same maximum-axis distance as the navigation deadband.
            func distance(_ zone: Zone) -> Double {
                let yaw = (zone.yaw.lowerBound + zone.yaw.upperBound) / 2
                let pitch = (zone.pitch.lowerBound + zone.pitch.upperBound) / 2
                return max(abs(yaw - origin.yaw), abs(pitch - origin.pitch))
            }
            guard let zone = zones.filter({ !$0.forbidden }).min(by: { distance($0) < distance($1) }) else {
                throw LabSkipped("No hay zona permitida guardada")
            }
            guard distance(zone) <= 20 else {
                throw LabSkipped("zona demasiado lejos: el navegador avanza ~1,2 °/s y el plazo es de 25 s; acerca la Osmo o guarda una zona a ≤ 20°")
            }
            guard referenceConfirmed else { throw LabSkipped("Referencia humana sin confirmar") }
            let lease = try await controller.requestLease(source: .app, zone: zone.name, seconds: 30)
            let arrival = try await guardedGoto(zone: zone.name, lease: lease, origin: origin)
            await controller.release(lease: lease)
            let yaw = (zone.yaw.lowerBound + zone.yaw.upperBound) / 2
            let pitch = (zone.pitch.lowerBound + zone.pitch.upperBound) / 2
            let error = max(abs(arrival.yaw - yaw), abs(arrival.pitch - pitch))
            guard error <= 2.5 else { throw LabTestFailure("Error de llegada \(error)°", ["center_error_degrees": error]) }
            return ["center_error_degrees": error]
        case .constantTelemetry:
            let since = clock.now()
            try await wait(2, origin: origin)
            let values = await frames.constantTelemetry().filter { $0.receivedAt >= since }
            guard values.count >= 3, let first = values.first?.payload,
                  values.allSatisfy({ $0.payload == first }) else { throw LabTestFailure("0x04/0x57 ausente o cambiante", ["constant_frames": Double(values.count)]) }
            return ["constant_frames": Double(values.count)]
        }
    }
    private func wait(_ seconds: Double, origin: Pose, refresh: MoveCommand? = nil) async throws {
        _ = try await observe(seconds, measureFrom: origin, safetyOrigin: origin, refresh: refresh)
    }
    /// `refresh`: orden de velocidad que se reenvía cada 0,3 s. Medido en la SE: cada orden SPEED dura solo ~0,5 s,
    /// así que un movimiento continuo exige refrescarla (y el deadman del controlador también lo exige).
    private func observe(_ seconds: Double, measureFrom reference: Pose, safetyOrigin: Pose,
                         refresh: MoveCommand? = nil) async throws -> Double {
        let steps = max(1, Int(ceil(seconds / 0.1)))
        var maximum = 0.0
        for step in 0..<steps {
            try Task.checkCancellation()
            try await clock.sleep(seconds / Double(steps))
            if let refresh, (step + 1) % 3 == 0, step + 1 < steps { try await controller.send(refresh, source: .app) }
            guard let sample = await device.poseSample(), sample.pose.isFinite else { throw LabTestFailure("Pose ausente o no finita") }
            let age = clock.now().timeIntervalSince(sample.receivedAt)
            guard age >= 0, age <= limits.staleSeconds else { throw LabTestFailure("Pose desactualizada durante la prueba", ["pose_age_seconds": age]) }
            let pose = sample.pose
            let safetyDeviation = max(abs(pose.yaw - safetyOrigin.yaw), abs(pose.pitch - safetyOrigin.pitch))
            guard safetyDeviation <= 45 else { throw LabTestFailure("Aborto de seguridad: orientación >45° del origen", ["deviation_degrees": safetyDeviation]) }
            maximum = max(maximum, max(abs(pose.yaw - reference.yaw), abs(pose.pitch - reference.pitch)))
        }
        return maximum
    }
    private func guardedGoto(zone: String, lease: Lease, origin: Pose) async throws -> Pose {
        let result = LabNavigationResult()
        let navigation = Task {
            do { await result.finish(.success(try await navigator.go(to: zone, source: .app, lease: lease))) }
            catch { await result.finish(.failure(error)) }
        }
        let watcher = Task {
            do {
                while true {
                    try Task.checkCancellation()
                    try await clock.sleep(0.1)
                    guard let sample = await device.poseSample(), sample.pose.isFinite else { throw LabTestFailure("Pose ausente durante ir a zona") }
                    let age = clock.now().timeIntervalSince(sample.receivedAt)
                    guard age >= 0, age <= limits.staleSeconds else { throw LabTestFailure("Pose desactualizada durante ir a zona", ["pose_age_seconds": age]) }
                    let pose = sample.pose
                    let deviation = max(abs(pose.yaw - origin.yaw), abs(pose.pitch - origin.pitch))
                    guard deviation <= 45 else {
                        let failure = LabTestFailure("Aborto de seguridad: orientación >45° del origen", ["deviation_degrees": deviation])
                        await result.finish(.failure(failure))
                        navigation.cancel(); await controller.stop(source: .app)
                        throw failure
                    }
                }
            } catch { if !Task.isCancelled { await result.finish(.failure(error)) } }
        }
        defer { navigation.cancel(); watcher.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await result.value()
        } onCancel: {
            Task { navigation.cancel(); await controller.stop(source: .app); await result.finish(.failure(CancellationError())) }
        }
    }
    private func result(_ kind: LabTestKind, _ status: LabTestStatus, _ summary: String,
                        _ values: [String: Double], _ started: Date) -> LabTestResult {
        let elapsed = max(0, clock.now().timeIntervalSince(started))
        return LabTestResult(kind: kind, status: status, summary: summary, measurements: values, durationSeconds: elapsed)
    }
}

private actor LabNavigationResult {
    private var result: Result<Pose, any Error>?
    private var waiter: CheckedContinuation<Pose, any Error>?
    func finish(_ result: Result<Pose, any Error>) {
        guard self.result == nil else { return }
        self.result = result; waiter?.resume(with: result); waiter = nil
    }
    func value() async throws -> Pose {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}

private struct LabTestFailure: Error, CustomStringConvertible {
    let description: String
    let measurements: [String: Double]
    init(_ description: String, _ measurements: [String: Double] = [:]) { self.description = description; self.measurements = measurements }
}
private struct LabSkipped: Error, CustomStringConvertible { let description: String; init(_ description: String) { self.description = description } }

public enum LabReport {
    public static func markdown(results: [LabTestResult], date: Date) -> String {
        let lines = results.map { result in
            let values = result.measurements.keys.sorted().map { "\($0): \(result.measurements[$0]!)" }.joined(separator: ", ")
            return "- **\(result.statusText)** \(result.name) — \(result.summary); \(values); \(String(format: "%.2f", result.durationSeconds)) s"
        }
        let summary = "PASA: \(results.filter { $0.status == .passed }.count) · FALLA: \(results.filter { $0.status == .failed }.count) · SALTADA: \(results.filter { $0.status == .skipped }.count)"
        return (["# Informe GimbalLab — \(date.ISO8601Format())", "", summary, "", "## Resultados", ""] + lines + [""]).joined(separator: "\n")
    }
}
