import Foundation
import GimbalKit
import GimbalKitDJI

public struct LabAutoRunArgumentError: Error, Sendable, CustomStringConvertible {
    public let description: String
}

public struct LabAutoRunOptions: Sendable {
    public let outputURL: URL
    public let tests: [LabTestKind]

    /// Arguments exclude argv[0]. Other app arguments are ignored without the explicit opt-in.
    public static func parse(_ arguments: [String]) throws -> Self? {
        guard arguments.contains("--auto-run") else { return nil }
        var output: String?
        var selection: [LabTestKind]?
        var flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flags.insert(flag).inserted else { throw error("Argumento repetido: \(flag)") }
            switch flag {
            case "--auto-run": break
            case "--out", "--solo":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty,
                      !arguments[index].hasPrefix("--") else { throw error("Falta el valor de \(flag)") }
                let value = arguments[index]
                if flag == "--out" { output = value }
                else {
                    let names: [String: LabTestKind] = ["yaw": .yawMovement, "reposo": .restStability,
                        "bateria": .battery, "parada": .stop, "telemetria": .constantTelemetry]
                    var kinds: [LabTestKind] = []
                    for name in value.split(separator: ",", omittingEmptySubsequences: false) {
                        guard let kind = names[String(name)] else { throw error("Prueba desconocida: \(name)") }
                        if !kinds.contains(kind) { kinds.append(kind) }
                    }
                    selection = kinds
                }
            default: throw error("Argumento desconocido: \(flag)")
            }
            index += 1
        }
        guard let output else { throw error("--auto-run requiere --out <ruta.md>") }
        return Self(outputURL: URL(fileURLWithPath: output), tests: selection ?? LabTestKind.allCases)
    }
    private static func error(_ message: String) -> LabAutoRunArgumentError { .init(description: message) }
}

/// A single unattended session. The macOS entry point owns the host lock and process lifetime.
public actor LabAutoRunSession {
    private let link: any LabLink
    private let store: ZoneStore
    private let observed: LabObservedTransport
    private let omDevice: OMDevice
    private let device: any PoseFeedbackDevice
    private let controller: GimbalController
    private let frames = LabFrameBuffer()
    private let battery: @Sendable () async -> LabBattery?
    private let clock: RuntimeClock
    private let output: @Sendable (String) -> Void
    private var started = false

    public init(link: any LabLink, store: ZoneStore, device: (any PoseFeedbackDevice)? = nil,
                battery: (@Sendable () async -> LabBattery?)? = nil,
                clock: RuntimeClock = .live, output: @escaping @Sendable (String) -> Void) {
        self.link = link; self.store = store; self.clock = clock; self.output = output
        let observed = LabObservedTransport(base: link, now: clock.now)
        let omDevice = OMDevice(transport: observed, now: clock.now)
        self.observed = observed; self.omDevice = omDevice
        self.device = device ?? omDevice
        self.battery = battery ?? { await omDevice.battery.map { LabBattery(percent: $0.percent, charging: $0.charging) } }
        controller = GimbalController(device: device ?? omDevice,
            policy: SafetyPolicy(maxSpeed: 12, maxLeaseSeconds: 30, deadmanSeconds: 0.75, zones: []), now: clock.now)
    }

    public func run(_ options: LabAutoRunOptions?) async -> Int32? {
        guard let options else { return nil }
        guard !started else { return 1 }
        started = true
        var results: [LabTestResult] = []
        var phases: [String] = []
        var exitCode: Int32 = 0
        var connected = false
        let frameTask = Task { [frames, stream = observed.frameEvents] in
            for await frame in stream {
                guard !Task.isCancelled else { break }
                await frames.append(frame)
            }
        }
        func phase(_ message: String) { phases.append(message); output("LAB \(message)") }
        phase("Bluetooth autorización: \(link.bluetoothAuthorization)")
        do {
            try Task.checkCancellation()
            phase("Conexión: iniciando (plazo 20 s)")
            try await connectWithDeadline()
            connected = true
            try Task.checkCancellation()
            phase("Bluetooth autorización: \(link.bluetoothAuthorization)")
            phase("Conexión: PASA")
            let zones = try await store.load()
            await controller.replaceZones(zones)
            await omDevice.start()
            // Notifications may arrive just after service discovery completes.
            let deadline = clock.now().addingTimeInterval(3)
            while await device.poseSample() == nil, clock.now() < deadline {
                try Task.checkCancellation()
                try await clock.sleep(0.1)
            }
            let runner = LabHardwareTestRunner(transport: observed, device: device, controller: controller,
                navigator: GotoNavigator(controller: controller, clock: clock), store: store, frames: frames,
                battery: battery, clock: clock)
            // Persisted zones still require the existing human reference confirmation.
            await runner.setReferenceConfirmed(zones.isEmpty)
            for kind in options.tests {
                try Task.checkCancellation()
                let result: LabTestResult
                if exitCode == 1 {
                    result = LabTestResult(kind: kind, status: .skipped, summary: "Batería abortada tras un fallo",
                        measurements: [:], durationSeconds: 0)
                } else { result = await runner.run(kind) }
                results.append(result)
                let measures = result.measurements.keys.sorted().map { "\($0)=\(result.measurements[$0]!)" }.joined(separator: " ")
                phase("\(result.name): \(result.statusText) \(result.summary) \(measures) duration_seconds=\(result.durationSeconds)")
                if result.status == .failed { exitCode = 1 }
            }
            try Task.checkCancellation()
        } catch {
            exitCode = !connected && !(error is CancellationError) ? 2 : 1
            phase("\(connected ? "Ejecución" : "Conexión"): FALLA \(error)")
        }
        // Await STOP before tearing down the link, even in a cancelled task.
        await controller.stop(source: .app)
        phase("Parada final: STOP solicitado")
        frameTask.cancel()
        await omDevice.shutdown()
        await link.disconnect()
        do {
            try FileManager.default.createDirectory(at: options.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let report = LabReport.markdown(results: results, date: clock.now())
                + "\n## Ciclo automático\n\n" + phases.map { "- \($0)" }.joined(separator: "\n") + "\n"
            try report.write(to: options.outputURL, atomically: true, encoding: .utf8)
            output("LAB Informe: \(options.outputURL.path)")
        } catch {
            exitCode = 1
            output("LAB Informe: FALLA \(error)")
        }
        output("LAB SALIDA \(exitCode)")
        return exitCode
    }

    private func connectWithDeadline() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [link] in try await link.connect() }
            group.addTask { [clock] in
                try await clock.sleep(20)
                try Task.checkCancellation()
                throw LabAutoRunConnectionTimeout()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}

private struct LabAutoRunConnectionTimeout: Error, CustomStringConvertible {
    var description: String { "No conectó en 20 s" }
}
