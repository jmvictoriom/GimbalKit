import AppKit
import Charts
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers
import Darwin
import GimbalKit
import GimbalKitBLE
import GimbalKitDJI
import GimbalHostSupport
import GimbalLabSupport

final class BLELabLink: LabLink, @unchecked Sendable {
    private let transport = CoreBluetoothOMTransport()
    let notifications: AsyncStream<[UInt8]>
    let disconnects: AsyncStream<Void>
    private let disconnectContinuation: AsyncStream<Void>.Continuation
    private let timeout: TimeInterval
    var bluetoothAuthorization: LabBluetoothAuthorization {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }
    init(timeout: TimeInterval = 15) {
        self.timeout = timeout
        notifications = transport.notifications
        let pair = AsyncStream.makeStream(of: Void.self)
        disconnects = pair.stream; disconnectContinuation = pair.continuation
        transport.onDisconnect = { pair.continuation.yield(()) }
    }
    func connect() async throws { try await transport.connect(timeout: timeout) }
    func disconnect() async { transport.disconnect(); disconnectContinuation.finish() }
    func write(_ bytes: [UInt8]) async throws { try await transport.write(bytes) }
}

@MainActor enum LabComposition {
    static let result: Result<(LabModel, HostInstanceLock), any Error> = Result {
        let directory = ZoneStore.defaultURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = try HostInstanceLock(directory: directory)
        return (LabModel(store: ZoneStore()), lock)
    }
}

@main @MainActor enum GimbalLabEntryPoint {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--auto-run") else { GimbalLabApp.main(); return }
        let options: LabAutoRunOptions
        do { options = try LabAutoRunOptions.parse(arguments)! }
        catch { log("LAB Argumentos: FALLA \(error)"); exit(1) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let task = Task { @MainActor in
            let code = await runAutomatic(options)
            exit(code)
        }
        let delegate = LabAutoTerminationDelegate { task.cancel() }
        application.delegate = delegate
        // Dispatch sources allow async STOP outside the POSIX signal handler.
        let sources = [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { log("LAB Terminación: señal \(number)"); task.cancel() }
            source.resume()
            return source
        }
        withExtendedLifetime((delegate, sources)) { application.run() }
    }

    private static func runAutomatic(_ options: LabAutoRunOptions) async -> Int32 {
        do {
            let directory = ZoneStore.defaultURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lock = try HostInstanceLock(directory: directory)
            defer { withExtendedLifetime(lock) {} }
            log("LAB Control: HostInstanceLock adquirido")
            let session = LabAutoRunSession(link: BLELabLink(timeout: 20), store: ZoneStore(), output: log)
            return await session.run(options) ?? 1
        } catch {
            // A competing owner must retain exclusive control; do not create a BLE link here.
            log("LAB Control: FALLA \(error)")
            do {
                try FileManager.default.createDirectory(at: options.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let report = LabReport.markdown(results: [], date: Date())
                    + "\n## Ciclo automático\n\n- **FALLA** Control: \(error)\n- No se adquirió el control exclusivo; transporte sin iniciar.\n"
                try report.write(to: options.outputURL, atomically: true, encoding: .utf8)
                log("LAB Informe: \(options.outputURL.path)")
            } catch { log("LAB Informe: FALLA \(error)") }
            log("LAB SALIDA 1")
            return 1
        }
    }

    nonisolated private static func log(_ line: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }
}

@MainActor private final class LabAutoTerminationDelegate: NSObject, NSApplicationDelegate {
    private let cancel: () -> Void
    init(cancel: @escaping () -> Void) { self.cancel = cancel }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cancel()
        return .terminateLater
    }
}

@MainActor struct GimbalLabApp: App {
    @State private var model: LabModel?
    @State private var lock: HostInstanceLock?
    @State private var startupError: String?
    init() {
        if case let .success((model, lock)) = LabComposition.result {
            _model = State(initialValue: model); _lock = State(initialValue: lock)
        } else if case let .failure(error) = LabComposition.result {
            _model = State(initialValue: nil); _lock = State(initialValue: nil)
            _startupError = State(initialValue: String(describing: error))
        }
    }
    var body: some Scene {
        WindowGroup("GimbalLab") {
            if let model { LabView(model: model) }
            else { VStack(spacing: 12) {
                Text("No se pudo adquirir el control de la Osmo.").font(.headline)
                Text(startupError ?? "Otro anfitrión puede estar abierto.")
                Button("Salir") { NSApplication.shared.terminate(nil) }
            }.padding(30) }
        }.defaultSize(width: 1120, height: 820)
    }
}

@MainActor struct LabView: View {
    @Bindable var model: LabModel
    @State private var speed = 6.0
    @State private var phase = "pre"
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("GimbalLab").font(.largeTitle.bold())
                Text("Bluetooth: \(model.authorizationText) · \(model.connectionText)")
                if let battery = model.battery { Text("Batería: \(battery.percent)%\(battery.charging ? " · cargando" : "")") }
                if let pose = model.pose {
                    Text("Yaw \(pose.yaw, specifier: "%.1f")° · Pitch \(pose.pitch, specifier: "%.1f")° · Roll \(pose.roll, specifier: "%.1f")°")
                    Text(String(format: "%.2f Hz · trama hace %.2f s", model.updateHz, model.poseAgeSeconds ?? 0))
                } else { Text("Pose no disponible o desactualizada") }
                Chart(model.poseHistory) { point in
                    LineMark(x: .value("Tiempo", point.date), y: .value("Yaw", point.pose.yaw), series: .value("Eje", "Yaw"))
                    LineMark(x: .value("Tiempo", point.date), y: .value("Pitch", point.pose.pitch), series: .value("Eje", "Pitch"))
                }.frame(height: 180)
                HStack {
                    Button(model.connection == .connected ? "Desconectar" : "Conectar") {
                        Task { if model.connection == .connected { await model.disconnect() } else { await model.connect(using: BLELabLink()) } }
                    }
                    Button("Reconectar") { Task { await model.reconnect(makeLink: { BLELabLink() }) } }
                    Button("PARADA", role: .destructive) { Task { await model.stopAll() } }
                        .font(.title2.bold()).buttonStyle(.borderedProminent).tint(.red)
                }
                Text("Mando manual · máximo 12 °/s").font(.headline)
                Slider(value: $speed, in: 0...12, step: 0.5)
                HStack {
                    hold("Yaw −", axis: .yaw, direction: -1); hold("Yaw +", axis: .yaw, direction: 1)
                    hold("Pitch −", axis: .pitch, direction: -1); hold("Pitch +", axis: .pitch, direction: 1)
                }
                TextField("Fase de grabación", text: $phase)
                HStack {
                    Button("Grabar JSONL") { saveJSONL() }
                    Button("Detener grabación") { Task { await model.stopRecording() } }
                    Button("Ejecutar todas") { Task { await model.runAllTests() } }
                }
                HStack {
                    Button("Exportar informe Markdown") { exportReport() }
                    Button("Ir a zona") { Task { await model.go(to: model.firstAllowedZoneName) } }
                        .disabled(!model.referenceConfirmed || model.firstAllowedZoneName == nil)
                }
                ForEach(model.testResults) { result in
                    Text("\(result.statusText) · \(result.name) · \(result.durationSeconds, specifier: "%.2f") s · \(result.summary)")
                        .font(.caption).foregroundStyle(result.status == .failed ? .red : .primary)
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Tramas · \(model.validFrameCount) válidas / \(model.invalidFrameCount) CRC inválido").font(.headline)
                HStack {
                    TextField("commandSet hex", text: $model.commandSetFilter)
                    TextField("command hex", text: $model.commandFilter)
                    Toggle("Pausar lista", isOn: $model.isFrameListPaused)
                }
                List(model.visibleFrames) { frame in
                    Text(String(format: "%@  0x%02x/0x%02x  %@", frame.crcValid ? "OK" : "CRC", frame.commandSet ?? 0, frame.command ?? 0, frame.hex))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Text("Zonas guardadas").font(.headline)
                ForEach(model.zones, id: \.name) { zone in
                    HStack {
                        Text("\(zone.name) · yaw \(zone.yaw.lowerBound, specifier: "%.1f")...\(zone.yaw.upperBound, specifier: "%.1f") · pitch \(zone.pitch.lowerBound, specifier: "%.1f")...\(zone.pitch.upperBound, specifier: "%.1f")\(zone.forbidden ? " · prohibida" : "")")
                        Spacer()
                        Button("Ir") { Task { await model.go(to: zone.name) } }
                            .disabled(zone.forbidden || !model.referenceConfirmed || model.connection != .connected)
                    }
                }
                if !model.zones.isEmpty && !model.referenceConfirmed {
                    Text("Compruebe la referencia física y las zonas guardadas antes de habilitar navegación.")
                    Button("Confirmar referencia") { Task { await model.confirmReference() } }
                }
            }.frame(minWidth: 460)
        }
        .padding(18)
        .onChange(of: phase) { _, value in Task { await model.setPhase(value) } }
        .onDisappear { Task { await model.stopAll(); await model.disconnect() } }
    }
    private func hold(_ title: String, axis: LabAxis, direction: Int) -> some View {
        Button(title) {}
            .buttonStyle(.borderedProminent)
            .disabled(model.connection != .connected)
            .onLongPressGesture(minimumDuration: 0, pressing: { pressed in
                if pressed { model.startManual(axis: axis, direction: direction, speed: speed) }
                else { Task { await model.endManual() } }
            }, perform: {})
    }
    private func exportReport() {
        let panel = NSSavePanel()
        let stamp = DateFormatter(); stamp.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "informe-lab-\(stamp.string(from: Date())).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try model.exportReport(to: url) }
            catch { model.presentError(String(describing: error)) }
        }
    }
    private func saveJSONL() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "gimbalkit-session.jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do { try await model.startRecording(at: url); await model.setPhase(phase) }
                catch { model.presentError(String(describing: error)) }
            }
        }
    }
}
