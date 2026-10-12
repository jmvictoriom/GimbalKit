#if os(macOS)
import Foundation
import Observation
import GimbalKit
import GimbalKitMCP

@MainActor @Observable public final class HostModel {
    public var port = 9347
    public private(set) var status = GimbalStatus(connected: false, referenceReady: false, battery: nil, pose: nil, lease: nil)
    public private(set) var zones: [ZoneRecord] = []
    public private(set) var audit: [AuditEntry] = []
    public private(set) var mcpEnabled = false
    public private(set) var activePort: UInt16?
    public private(set) var serverBusy = false
    public private(set) var zoneDraft: ZoneDraft?
    public private(set) var referenceDraft: ReferenceDraft?
    public var errorMessage: String?
    @ObservationIgnored private let runtime: HostRuntime
    @ObservationIgnored private let files: LocalFiles
    @ObservationIgnored private let instanceLock: HostInstanceLock?
    @ObservationIgnored private let serverFactory: @MainActor (any GimbalService, String) -> any MCPServerControl
    @ObservationIgnored private let clock: RuntimeClock
    @ObservationIgnored private var server: (any MCPServerControl)?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var updater: Task<Void, Never>?
    @ObservationIgnored private var serverTask: Task<Void, Never>?
    @ObservationIgnored private var serverGeneration = UUID()
    @ObservationIgnored private var started = false
    public init(runtime: HostRuntime, files: LocalFiles, instanceLock: HostInstanceLock? = nil,
                serverFactory: @escaping @MainActor (any GimbalService, String) -> any MCPServerControl,
                clock: RuntimeClock = .live) {
        self.runtime = runtime; self.files = files; self.instanceLock = instanceLock
        self.serverFactory = serverFactory; self.clock = clock
    }
    public func start() async {
        guard !started else { return }
        started = true
        do {
            token = try files.token(create: true)
            try files.removeEndpoint()
            try await runtime.start()
        } catch { errorMessage = "No se pudo iniciar el anfitrión."; started = false; return }
        guard started else { await runtime.shutdown(); return }
        updater = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                do { try await clock.sleep(0.2) } catch { break }
            }
        }
    }
    public func refresh() async {
        do {
            let state = try await runtime.status()
            let saved = await runtime.zones()
            let entries = await runtime.auditEntries()
            guard started, !Task.isCancelled else { return }
            status = state; zones = saved; audit = entries
        } catch { errorMessage = "No se pudo leer el estado." }
    }
    public func setMCPEnabled(_ enabled: Bool) async {
        let current = UUID(); serverGeneration = current
        let previous = serverTask
        previous?.cancel()
        await previous?.value
        guard serverGeneration == current else { return }
        serverBusy = true
        let task = Task { [weak self] in
            guard let self else { return }
            do { try await configureServer(enabled) }
            catch is CancellationError { }
            catch { errorMessage = "No se pudo cambiar el servidor MCP. Compruebe el puerto y el token local." }
            if serverGeneration == current { serverBusy = false }
        }
        serverTask = task
        await task.value
        if serverGeneration == current { serverTask = nil }
    }
    private func configureServer(_ enabled: Bool) async throws {
        if enabled {
            guard started, let token, (0...65535).contains(port) else { throw HTTPFailure(400) }
            if mcpEnabled { return }
            let created = serverFactory(runtime, token); server = created
            created.onUnexpectedTermination = { [weak self, weak created] in
                guard let self, let created else { return }
                self.serverTerminated(created)
            }
            do {
                let actual = try await created.start(port: UInt16(port))
                try Task.checkCancellation()
                try files.writeEndpoint(port: actual)
                activePort = actual; mcpEnabled = true
            } catch {
                await created.stop(); server = nil
                try? await runtime.stop(); try? files.removeEndpoint()
                activePort = nil; mcpEnabled = false
                throw error
            }
        } else {
            let previous = server; server = nil
            await previous?.stop()
            try? await runtime.stop()
            activePort = nil; mcpEnabled = false
            try files.removeEndpoint()
        }
    }
    private func serverTerminated(_ terminated: any MCPServerControl) {
        guard server === terminated else { return }
        let current = UUID(); serverGeneration = current
        let previous = serverTask
        previous?.cancel()
        server = nil; activePort = nil; mcpEnabled = false; serverBusy = true
        errorMessage = "El servidor MCP se ha detenido inesperadamente."
        try? files.removeEndpoint()
        // Publish the stop immediately; serialize cleanup before another start.
        serverTask = Task { [weak self] in
            guard let self else { return }
            await previous?.value
            await terminated.stop()
            try? await runtime.stop()
            await refresh()
            if serverGeneration == current { serverBusy = false; serverTask = nil }
        }
    }
    public func registrationCommand() -> String? {
        guard mcpEnabled, let activePort, let token else { return nil }
        // Port numérico y token hexadecimal: no insertar texto humano ni interpolar una zona.
        return "claude mcp add --transport http gimbalkit http://127.0.0.1:\(activePort)/mcp --header 'Authorization: Bearer \(token)'"
    }
    public func prepareZone(name: String, forbidden: Bool = false) async {
        do { zoneDraft = try await runtime.prepareZone(name: name, forbidden: forbidden) }
        catch { errorMessage = "No se puede guardar: revise nombre, pose y referencia." }
    }
    public func cancelZone() { zoneDraft = nil }
    public func confirmZone() async {
        guard let zoneDraft else { return }
        self.zoneDraft = nil
        do { try await runtime.confirmZone(zoneDraft); await refresh() }
        catch { errorMessage = "La pose o conexión cambió; vuelva a preparar la zona." }
    }
    public func prepareReference() async {
        do { referenceDraft = try await runtime.prepareReference() }
        catch { errorMessage = "Se necesita conexión y pose fresca para confirmar la referencia." }
    }
    public func cancelReference() { referenceDraft = nil }
    public func confirmReference() async {
        guard let referenceDraft else { return }
        self.referenceDraft = nil
        do { try await runtime.confirmReference(referenceDraft); await refresh() }
        catch { errorMessage = "La referencia cambió; vuelva a comprobar las zonas." }
    }
    public func humanStop() async { await runtime.humanStop(); await refresh() }
    public func shutdown() async {
        started = false
        let old = updater; updater = nil; old?.cancel(); await old?.value
        await setMCPEnabled(false)
        await runtime.shutdown()
        token = nil
    }
}
#endif
