import AppKit
import SwiftUI
import Foundation
import GimbalKit
import GimbalKitDJI
import GimbalKitBLE
import GimbalKitMCP
import GimbalHostSupport

final class BLEHostLink: HostLink, Sendable {
    let transport: CoreBluetoothOMTransport
    let disconnects: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    var notifications: AsyncStream<[UInt8]> { transport.notifications }
    init() {
        let pair = AsyncStream.makeStream(of: Void.self)
        disconnects = pair.stream; continuation = pair.continuation
        transport = CoreBluetoothOMTransport()
        transport.onDisconnect = { pair.continuation.yield(()) }
    }
    func connect() async throws { try await transport.connect(timeout: 15) }
    func disconnect() async { transport.disconnect(); continuation.finish() }
    func write(_ bytes: [UInt8]) async throws { try await transport.write(bytes) }
}

@MainActor enum HostComposition {
    static let result: Result<HostModel, any Error> = Result {
        let clock = RuntimeClock.live
        let files = try LocalFiles()
        let lock = try HostInstanceLock(directory: files.directory)
        let runtime = HostRuntime(makeLink: { BLEHostLink() }, store: ZoneStore(), clock: clock)
        return HostModel(runtime: runtime, files: files, instanceLock: lock,
                         serverFactory: { service, token in HTTPServer(service: service, token: token, clock: clock) }, clock: clock)
    }
}
@MainActor final class HostDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if case let .success(model) = HostComposition.result { Task { await model.start() } }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            if case let .success(model) = HostComposition.result { await model.shutdown() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
@main @MainActor struct GimbalHostApp: App {
    @NSApplicationDelegateAdaptor(HostDelegate.self) private var delegate
    @State private var model: HostModel?
    init() {
        if case let .success(model) = HostComposition.result { _model = State(initialValue: model) }
        else { _model = State(initialValue: nil) }
    }
    var body: some Scene {
        MenuBarExtra {
            if let model { HostMenu(model: model) }
            else {
                Text("No se pudo iniciar. Puede haber otro GimbalHostMac abierto.").padding()
                Button("Salir") { NSApplication.shared.terminate(nil) }
            }
        } label: {
            Label(model?.status.lease == nil ? "GimbalKit" : "GimbalKit: agente con control",
                  systemImage: model?.status.lease == nil ? "camera.aperture" : "eye.fill")
        }
        .menuBarExtraStyle(.window)
        Window("Registro de GimbalKit", id: "audit") {
            if let model { AuditView(model: model) }
            else { Text("Registro no disponible.") }
        }
    }
}

@MainActor struct HostMenu: View {
    @Bindable var model: HostModel
    @Environment(\.openWindow) private var openWindow
    @State private var name = ""
    @State private var forbidden = false
    @State private var serverRequested = false
    @State private var showZoneConfirmation = false
    @State private var showReferenceConfirmation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GimbalKit").font(.headline)
            Text(model.status.connected ? "Conectada" : "Desconectada · reintentando con retroceso")
            if let battery = model.status.battery { Text("Batería: \(battery.percent)%\(battery.charging ? " · cargando" : "")") }
            if let pose = model.status.pose { Text("Yaw \(pose.yaw, specifier: "%.1f")° · Pitch \(pose.pitch, specifier: "%.1f")° · Roll \(pose.roll, specifier: "%.1f")°") }
            else { Text("Pose no disponible o desactualizada") }
            if let lease = model.status.lease {
                Label("Un agente tiene el control de \(lease.zone)", systemImage: "eye.fill")
                    .font(.headline).foregroundStyle(.orange)
            }
            Button("PARADA", role: .destructive) { Task { await model.humanStop() } }
                .font(.title2.bold()).buttonStyle(.borderedProminent).tint(.red)
                .frame(maxWidth: .infinity).controlSize(.large)
                .accessibilityHint("Detiene el estabilizador y revoca el control del agente")
            Divider()
            Text("Zonas").font(.headline)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(model.zones, id: \.name) { zone in
                        Text("\(zone.name)\(zone.forbidden ? " · prohibida" : "")")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 100)
            if !model.status.referenceReady, !model.zones.isEmpty {
                Text("Compruebe físicamente que la referencia y las zonas siguen siendo correctas.")
                Button("Confirmar referencia de zonas") {
                    Task { await model.prepareReference(); showReferenceConfirmation = model.referenceDraft != nil }
                }.disabled(model.status.pose == nil)
            }
            TextField("Nombre de la zona", text: $name)
            Toggle("Zona prohibida", isOn: $forbidden)
            Button("Guardar zona aquí") {
                Task { await model.prepareZone(name: name, forbidden: forbidden); showZoneConfirmation = model.zoneDraft != nil }
            }.disabled(model.status.pose == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            TextField("Puerto MCP", value: $model.port, format: .number).disabled(model.mcpEnabled || model.serverBusy)
            Toggle("Servidor MCP", isOn: $serverRequested)
                .disabled(model.serverBusy)
                .onChange(of: serverRequested) { _, enabled in Task { await model.setMCPEnabled(enabled); serverRequested = model.mcpEnabled } }
            if let port = model.activePort { Text("127.0.0.1:\(port)/mcp").font(.caption).textSelection(.enabled) }
            Button("Copiar comando para Claude") {
                if let command = model.registrationCommand() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }.disabled(!model.mcpEnabled)
            Button("Ver registro de auditoría") { openWindow(id: "audit") }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            Button("Salir") { NSApplication.shared.terminate(nil) }
        }
        .padding().frame(width: 390)
        .alert("Guardar zona aquí", isPresented: $showZoneConfirmation) {
            Button("Guardar") { Task { await model.confirmZone(); name = "" } }
            Button("Cancelar", role: .cancel) { model.cancelZone() }
        } message: {
            if let draft = model.zoneDraft {
                Text("Crear ‘\(draft.zone.name)’\(draft.zone.forbidden ? " (prohibida)" : "") con ±10° alrededor de yaw \(draft.pose.yaw, specifier: "%.1f")° y pitch \(draft.pose.pitch, specifier: "%.1f")°.")
            }
        }
        .alert("Confirmar referencia", isPresented: $showReferenceConfirmation) {
            Button("He comprobado las zonas") { Task { await model.confirmReference() } }
            Button("Cancelar", role: .cancel) { model.cancelReference() }
        } message: {
            Text("La orientación inicial de esta conexión es el cero. Confirme solo tras comprobar físicamente todas las zonas guardadas y las prohibidas.")
        }
    }
}
@MainActor struct AuditView: View {
    let model: HostModel
    private func line(_ entry: AuditEntry) -> String {
        let source: String
        switch entry.source {
        case .app?: source = "App"
        case .physical?: source = "Mando físico"
        case .shortcut?: source = "Atajo"
        case let .agent(name)?: source = "Agente \(name)"
        case nil: source = "Sistema"
        }
        let result: String
        switch entry.outcome {
        case .accepted: result = "Aceptada"
        case let .rejected(reason): result = "Rechazada: \(reason)"
        }
        return "\(entry.date.ISO8601Format()) | \(source) | \(entry.event) | \(result)"
    }
    var body: some View {
        ScrollView {
            Text(model.audit.map(line).joined(separator: "\n"))
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }.frame(minWidth: 700, minHeight: 400)
    }
}
