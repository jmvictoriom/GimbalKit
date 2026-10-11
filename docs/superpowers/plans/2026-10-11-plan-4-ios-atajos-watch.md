# GimbalKit — Plan 4: iOS, Atajos y mando Apple Watch

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans (recommended). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Crear una app anfitriona de iPhone, acciones Siri/Atajos y una app Watch que mande órdenes al iPhone. El iPhone mantiene la única conexión BLE; el núcleo de seguridad y la lógica se prueban en macOS sin hardware.

**Architecture:** `GimbalPhone` comparte una instancia de `HostRuntime` entre SwiftUI, App Intents y `PhoneWatchService`. `GimbalKitIntents` separa la lógica de acciones del framework App Intents. `GimbalWatchKit` define mensajes Codable y recepción segura en iPhone; el reloj solo transmite intención con `WCSession`, sin CoreBluetooth. MCP y `flock` siguen siendo código macOS.

**Tech Stack:** Swift 6, concurrencia estricta, Swift Testing, SwiftUI, App Intents (iOS 17+), WatchConnectivity/WatchKit (watchOS 10+), XcodeGen y SwiftPM local. Cero dependencias de terceros.

**Spec:** `docs/superpowers/specs/2026-10-11-gimbalkit-v1-design.md` (§3, §4, §6 y §8; M5), Plan 3 y su implementación real en `Sources/` y `Tests/`, `docs/research/telemetria-om-se.md` y `docs/superpowers/plans/ESTADO.md`. HID/joystick sigue sin soporte.

## Global Constraints

- El redactor solo crea este plan. No implementa, compila, ejecuta pruebas, conecta hardware, lanza simuladores, usa la red ni hace commits.
- El implementador tampoco puede hacer commits en este sandbox. Cada Step «Commit» es entrega a Claude; no ejecutar `git add` ni `git commit`.
- Ejecutar una sola suite/compilación Swift a la vez: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`. No esconder errores con `tail` o tuberías sin `pipefail`.
- Pruebas automáticas con Swift Testing, reloj inyectado, continuaciones y runtimes falsos. Ninguna abre CoreBluetooth, WCSession, sockets o simuladores. Lo que requiera iPhone, Watch u Osmo queda en la tarea manual final.
- `GimbalKitBLE` conserva `CoreBluetoothOMTransport`. `GimbalPhone` es la única dueña de Bluetooth en iOS. Atajos y Watch comparten `HostRuntime` y nunca crean otro central. iOS no arranca `GimbalKitMCP` ni listener.
- Separación mínima: mover DTOs compartidos fuera de MCP; condicionar dependencia MCP, `HostModel` y `HostInstanceLock` a macOS; mantener runtime, enlace BLE y `PhoneModel` portables. `Network.framework`, archivos locales MCP y `flock` solo en macOS.
- Toda orden pasa por `GimbalController` y `SafetyPolicy`. Atajos usan `.shortcut` sin privilegios; Watch y botones humanos usan `.app`, pero no eluden el límite de velocidad de política. Rechazar valores inválidos tipadamente.
- Las referencias se invalidan en cada conexión BLE nueva. Las zonas siguen visibles pero no operables hasta que una persona confirma la referencia. Guardar zona siempre requiere confirmación humana.
- El spike de reconexión en segundo plano va temprano: intent y runtime falso prueban timeout de 10 s; movimiento usa `openAppWhenRun = true` y error claro. La reconexión BLE real se mide en la tarea manual.
- XcodeGen se ejecuta como `/opt/homebrew/bin/xcodegen` desde `Apps/`. Build genérico para simulador, sin firma; no lanzar simuladores. No preparar firma para dispositivo ni perfiles.
- Cada tarea automática termina con prueba o build y commit futuro de Claude en español. Tareas manuales al final.

## Review Focus

- Carreras STOP/orden; parada prioritaria; ningún SPEED antiguo tras STOP.
- Mensajes repetidos/fuera de secuencia, timestamp futuro o de más de 0,6 s, no finitos, malformados y zonas inexistentes: rechazo tipado, cero movimiento.
- Jog ≤12 °/s en protocolo, además del máximo `SafetyPolicy` actual de 6 °/s; cadencia BLE ≥0,25 s; deadman 0,6 s.
- Pérdida de `isReachable` con jog/look activo causa parada inmediata. Una tarea cancelada no reanuda movimiento.
- Zona desconocida/prohibida, pose no fresca, lease ocupado, referencia invalidada y Osmo desconectada: no mover.
- `requestConfirmation` precede a persistir; cancelar no escribe.
- Intent en background: intento limitado a 10 s, cancelable y con error claro/`openAppWhenRun`.
- `NSBluetoothAlwaysUsageDescription`, background `bluetooth-central`, targets/plataformas XcodeGen, concurrencia Swift 6 y builds sin firma.
- El target Watch no importa CoreBluetooth ni depende de `GimbalKitBLE`; solo manda comandos al iPhone.

## File Structure

```text
Package.swift
Sources/GimbalKit/HostStatus.swift
Sources/GimbalKitMCP/GimbalService.swift
Sources/GimbalHostSupport/
  HostRuntime.swift
  HostMCPService.swift
  HostModel.swift
  HostInstanceLock.swift
  CoreBluetoothHostLink.swift
  PhoneModel.swift
  PhoneHostComposition.swift
Sources/GimbalKitIntents/
  ShortcutActionService.swift
  HostShortcutRuntime.swift
  PhoneShortcutComposition.swift
  GimbalKitAppIntents.swift
Sources/GimbalWatchKit/
  WatchMessages.swift
  PhoneWatchService.swift
  HostWatchRuntime.swift
Sources/GimbalHostMac/GimbalHostApp.swift
Apps/project.yml
Apps/GimbalPhone/GimbalPhoneApp.swift
Apps/GimbalPhone/PhoneHomeView.swift
Apps/GimbalPhone/PhoneWatchBridge.swift
Apps/GimbalWatch/GimbalWatchApp.swift
Apps/GimbalWatch/WatchHomeView.swift
Tests/GimbalHostSupportTests/PhoneModelTests.swift
Tests/GimbalKitIntentsTests/ShortcutActionServiceTests.swift
Tests/GimbalWatchKitTests/WatchMessagesTests.swift
Tests/GimbalWatchKitTests/PhoneWatchServiceTests.swift
```

---

### Task 1: Compartir estado y aislar soporte macOS

**Files:**
- Create: `Sources/GimbalKit/HostStatus.swift`, `Sources/GimbalHostSupport/HostMCPService.swift`, `Sources/GimbalHostSupport/CoreBluetoothHostLink.swift`, `Sources/GimbalHostSupport/PhoneModel.swift`, `Sources/GimbalHostSupport/PhoneHostComposition.swift`
- Modify: `Package.swift`, `Sources/GimbalKitMCP/GimbalService.swift`, `Sources/GimbalHostSupport/HostRuntime.swift`, `Sources/GimbalHostSupport/HostModel.swift`, `Sources/GimbalHostSupport/HostInstanceLock.swift`, `Sources/GimbalHostMac/GimbalHostApp.swift`
- Test: `Tests/GimbalHostSupportTests/PhoneModelTests.swift`

**Interfaces:**
- Consumes: `HostRuntime`, `CoreBluetoothOMTransport`, `RuntimeClock`, `ZoneStore`, `GimbalService`, `ZoneDraft`, `ReferenceDraft`.
- Produces: DTOs `BatteryStatus`, `LeaseStatus`, `GimbalStatus`, `GimbalLookResult` en `GimbalKit`; `CoreBluetoothHostLink(timeout:)`; `PhoneModel`; `PhoneHostComposition.runtime/model`. `HostRuntime` deja de conformar a MCP; `HostMCPService` lo adapta solo en macOS.

Para que `PhoneModel` compile en esta tarea, sustituir los miembros de navegación de `HostRuntime` por:
```swift
public func look(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult {
    try await performLook(zone: zone, source: .agent("mcp"), leaseSeconds: leaseSeconds)
}
public func appLook(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult {
    try await performLook(zone: zone, source: .app, leaseSeconds: leaseSeconds)
}
private func performLook(zone: String, source: ControlSource,
                         leaseSeconds: Double) async throws -> GimbalLookResult {
    guard let captured = rig else { throw SafetyViolation.poseUnavailable }
    guard referenceReady else { throw NavigationError.referenceRequired }
    guard leaseSeconds.isFinite, leaseSeconds > 0, leaseSeconds <= 30 else {
        throw SafetyViolation.invalidDuration
    }
    guard !looking, !editing else { throw NavigationError.busy }
    looking = true
    defer { looking = false }
    guard rig?.id == captured.id, referenceReady else { throw NavigationError.interrupted }
    let lease = try await captured.controller.requestLease(
        source: source, zone: zone, seconds: leaseSeconds
    )
    do {
        let arrival = try await captured.navigator.go(to: zone, source: source, lease: lease)
        return GimbalLookResult(status: try await status(), arrivalPose: arrival)
    } catch {
        await captured.controller.release(lease: lease)
        throw error
    }
}
```

Task 2 sustituye estos tres miembros por el overload adicional `.shortcut`, el timeout de conexión y la navegación relativa.

Añadir a `HostRuntime` junto a los miembros de borrador:
```swift
public func cancelZone(_ draft: ZoneDraft) {
    guard pendingZone?.id == draft.id else { return }
    pendingZone = nil
}
public func cancelReference(_ draft: ReferenceDraft) {
    guard pendingReference?.id == draft.id else { return }
    pendingReference = nil
}
```

- [ ] **Step 1: Escribir la prueba que falla**

`Tests/GimbalHostSupportTests/PhoneModelTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit
@testable import GimbalHostSupport

@Test func hostStatusValuesArePortableCodable() throws {
    let value = GimbalStatus(
        connected: true, referenceReady: false,
        battery: BatteryStatus(percent: 72, charging: true),
        pose: Pose(yaw: 12.25, pitch: -3.5, roll: 0),
        lease: LeaseStatus(zone: "mesa", expiresAt: Date(timeIntervalSince1970: 20), remainingSeconds: 8)
    )
    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(GimbalStatus.self, from: data) == value)
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter hostStatusValuesArePortableCodable`
Expected: `GimbalStatus` y sus DTO aún están declarados en `GimbalKitMCP`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKit/HostStatus.swift`:
```swift
import Foundation

public struct BatteryStatus: Sendable, Codable, Equatable {
    public let percent: Int
    public let charging: Bool
    public init(percent: Int, charging: Bool) { self.percent = percent; self.charging = charging }
}
public struct LeaseStatus: Sendable, Codable, Equatable {
    public let zone: String
    public let expiresAt: Date
    public let remainingSeconds: Double
    public init(zone: String, expiresAt: Date, remainingSeconds: Double) {
        self.zone = zone; self.expiresAt = expiresAt; self.remainingSeconds = remainingSeconds
    }
}
public struct GimbalStatus: Sendable, Codable, Equatable {
    public let connected: Bool
    public let referenceReady: Bool
    public let battery: BatteryStatus?
    public let pose: Pose?
    public let lease: LeaseStatus?
    public init(connected: Bool, referenceReady: Bool, battery: BatteryStatus?, pose: Pose?, lease: LeaseStatus?) {
        self.connected = connected; self.referenceReady = referenceReady
        self.battery = battery; self.pose = pose; self.lease = lease
    }
}
public struct GimbalLookResult: Sendable, Codable, Equatable {
    public let status: GimbalStatus
    public let arrivalPose: Pose
    public init(status: GimbalStatus, arrivalPose: Pose) {
        self.status = status; self.arrivalPose = arrivalPose
    }
}
```

`Sources/GimbalKitMCP/GimbalService.swift` (reemplazar):
```swift
import GimbalKit

public protocol GimbalService: Sendable {
    func status() async throws -> GimbalStatus
    func zones() async throws -> [ZoneRecord]
    func look(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult
    func stop() async throws
}
```

`Sources/GimbalHostSupport/HostMCPService.swift`:
```swift
#if os(macOS)
import GimbalKit
import GimbalKitMCP

public struct HostMCPService: GimbalService {
    private let runtime: HostRuntime
    public init(runtime: HostRuntime) { self.runtime = runtime }
    public func status() async throws -> GimbalStatus { try await runtime.status() }
    public func zones() async throws -> [ZoneRecord] { await runtime.zones() }
    public func look(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult {
        try await runtime.look(zone: zone, leaseSeconds: leaseSeconds)
    }
    public func stop() async throws { try await runtime.stop() }
}
#endif
```

`Sources/GimbalHostSupport/CoreBluetoothHostLink.swift`:
```swift
import Foundation
import GimbalKitBLE

public final class CoreBluetoothHostLink: HostLink, Sendable {
    private let transport: CoreBluetoothOMTransport
    private let timeout: TimeInterval
    private let continuation: AsyncStream<Void>.Continuation
    public let disconnects: AsyncStream<Void>
    public var notifications: AsyncStream<[UInt8]> { transport.notifications }
    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
        let pair = AsyncStream.makeStream(of: Void.self)
        disconnects = pair.stream
        continuation = pair.continuation
        transport = CoreBluetoothOMTransport()
        transport.onDisconnect = { pair.continuation.yield(()) }
    }
    public func connect() async throws { try await transport.connect(timeout: timeout) }
    public func disconnect() async { transport.disconnect(); continuation.finish() }
    public func write(_ bytes: [UInt8]) async throws { try await transport.write(bytes) }
}
```

En `Sources/GimbalHostSupport/HostRuntime.swift`, eliminar `import GimbalKitMCP` y cambiar la declaración exacta `public actor HostRuntime: GimbalService {` a `public actor HostRuntime {`. Mantener los otros imports y miembros del actor.

En `Sources/GimbalHostSupport/HostModel.swift` y `HostInstanceLock.swift`, poner `#if os(macOS)` antes del primer import y `#endif` después del último `}` del fichero. En el miembro `configureServer(_:)`, sustituir:
```swift
let created = serverFactory(runtime, token)
```
por:
```swift
let created = serverFactory(HostMCPService(runtime: runtime), token)
```

En `GimbalHostMacApp.swift`, eliminar la clase local `BLEHostLink` completa y sustituir `HostComposition` por:
```swift
@MainActor enum HostComposition {
    static let result: Result<HostModel, any Error> = Result {
        let clock = RuntimeClock.live
        let files = try LocalFiles()
        let lock = try HostInstanceLock(directory: files.directory)
        let runtime = HostRuntime(
            makeLink: { CoreBluetoothHostLink(timeout: 15) },
            store: ZoneStore(), clock: clock
        )
        return HostModel(
            runtime: runtime, files: files, instanceLock: lock,
            serverFactory: { service, token in
                HTTPServer(service: service, token: token, clock: clock)
            },
            clock: clock
        )
    }
}
```

En `Package.swift`, reemplazar la entrada actual del target `GimbalHostSupport` por:
```swift
.target(name: "GimbalHostSupport", dependencies: [
    "GimbalKit", "GimbalKitDJI", "GimbalKitBLE",
    .target(name: "GimbalKitMCP", condition: .when(platforms: [.macOS]))
]),
```

Añadir `HostStatus.swift` a la lista de fuentes de `GimbalKit`; los nuevos targets de Atajos y Watch se incorporan en sus tareas. `HostModel` y `HostInstanceLock` quedan excluidos de iOS y `flock` no se porta.

`Sources/GimbalHostSupport/PhoneModel.swift`:
```swift
import Foundation
import Observation
import GimbalKit

@MainActor @Observable public final class PhoneModel {
    public private(set) var status = GimbalStatus(connected: false, referenceReady: false,
                                                  battery: nil, pose: nil, lease: nil)
    public private(set) var zones: [ZoneRecord] = []
    public private(set) var audit: [AuditEntry] = []
    public private(set) var zoneDraft: ZoneDraft?
    public private(set) var referenceDraft: ReferenceDraft?
    public var errorMessage: String?
    @ObservationIgnored private let runtime: HostRuntime
    @ObservationIgnored private let clock: RuntimeClock
    @ObservationIgnored private var updater: Task<Void, Never>?
    @ObservationIgnored private var started = false
    public init(runtime: HostRuntime, clock: RuntimeClock = .live) {
        self.runtime = runtime; self.clock = clock
    }
    public func start() async {
        guard !started else { return }
        started = true
        do { try await runtime.start() }
        catch { errorMessage = "No se pudo iniciar GimbalKit."; started = false; return }
        await refresh()
        updater = Task { [weak self, clock] in
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
    public func look(zone: String) async {
        do { _ = try await runtime.appLook(zone: zone, leaseSeconds: 30); await refresh() }
        catch { errorMessage = "No se pudo ir a la zona. Revise conexión y referencia." }
    }
    public func prepareZone(name: String) async {
        do { zoneDraft = try await runtime.prepareZone(name: name) }
        catch { errorMessage = "Se necesita una pose fresca y un nombre válido." }
    }
    public func cancelZone() async {
        if let draft = zoneDraft { await runtime.cancelZone(draft) }
        zoneDraft = nil
    }
    public func confirmZone() async {
        guard let draft = zoneDraft else { return }
        zoneDraft = nil
        do { try await runtime.confirmZone(draft); await refresh() }
        catch { errorMessage = "La pose o conexión cambió; prepare la zona otra vez." }
    }
    public func prepareReference() async {
        do { referenceDraft = try await runtime.prepareReference() }
        catch { errorMessage = "Se necesita conexión y pose fresca." }
    }
    public func cancelReference() async {
        if let draft = referenceDraft { await runtime.cancelReference(draft) }
        referenceDraft = nil
    }
    public func confirmReference() async {
        guard let draft = referenceDraft else { return }
        referenceDraft = nil
        do { try await runtime.confirmReference(draft); await refresh() }
        catch { errorMessage = "Compruebe las zonas y confirme de nuevo." }
    }
    public func humanStop() async { await runtime.humanStop(); await refresh() }
    public func shutdown() async {
        started = false
        let old = updater; updater = nil; old?.cancel(); await old?.value
        await runtime.shutdown()
    }
}
```

`Sources/GimbalHostSupport/PhoneHostComposition.swift`:
```swift
import GimbalKit

public enum PhoneHostComposition {
    public static let runtime = HostRuntime(
        makeLink: { CoreBluetoothHostLink(timeout: 10) },
        store: ZoneStore(),
        clock: .live
    )
    @MainActor public static let model = PhoneModel(runtime: runtime, clock: .live)
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: DTO Codable y suite existente pasan; `HostRuntime` ya no importa MCP. La build iOS se hace en Task 7.

- [ ] **Step 5: Commit** (Claude): `refactor: separar runtime iOS del host MCP macOS`

---

### Task 2: Lógica testeable de Atajos, timeout y movimiento relativo

**Files:**
- Create: `Sources/GimbalKitIntents/ShortcutActionService.swift`, `Sources/GimbalKitIntents/HostShortcutRuntime.swift`, `Sources/GimbalKitIntents/PhoneShortcutComposition.swift`
- Modify: `Package.swift`, `Sources/GimbalHostSupport/HostRuntime.swift`, `Sources/GimbalKit/GotoNavigator.swift`
- Test: `Tests/GimbalKitIntentsTests/ShortcutActionServiceTests.swift`

**Interfaces:**
- Consumes: Task 1 runtime/DTOs y Plan 3 `navigationContext`, `navigationPulse`, `haltNavigation`, `release`, `NavigationSafety`, `GotoNavigator`, `RuntimeClock`.
- Produces: `ShortcutActionRuntime`, `ShortcutActionService`, funciones puras para texto/validación, `waitUntilConnected(timeout:)`, look `.shortcut`/`.app`, stop `.shortcut`, movimiento relativo finito ≤15° por eje.

- [ ] **Step 1: Escribir la prueba que falla**

`Tests/GimbalKitIntentsTests/ShortcutActionServiceTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit
import GimbalHostSupport
@testable import GimbalKitIntents

actor FakeShortcutRuntime: ShortcutActionRuntime {
    var connected = true
    private(set) var lookedAt: String?
    private(set) var stopped = false
    private(set) var requestedTimeout: Double?
    func setConnected(_ value: Bool) { connected = value }
    func start() async throws {}
    func status() async throws -> GimbalStatus {
        GimbalStatus(connected: connected, referenceReady: true,
                     battery: BatteryStatus(percent: 70, charging: false),
                     pose: connected ? Pose(yaw: 1, pitch: 2) : nil, lease: nil)
    }
    func zones() async -> [ZoneRecord] {
        [ZoneRecord(Zone(name: "mesa", yaw: -30...30, pitch: -20...20))]
    }
    func waitUntilConnected(timeout: Double) async throws -> Bool {
        requestedTimeout = timeout
        return connected
    }
    func shortcutLook(zone: String) async throws -> GimbalLookResult {
        lookedAt = zone
        return GimbalLookResult(status: try await status(), arrivalPose: Pose())
    }
    func appLook(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult {
        try await shortcutLook(zone: zone)
    }
    func shortcutMoveRelative(yaw: Double, pitch: Double) async throws -> Pose {
        Pose(yaw: 1 + yaw, pitch: 2 + pitch)
    }
    func shortcutStop() async { stopped = true }
    func prepareZone(name: String) async throws -> ZoneDraft {
        ZoneDraft(id: UUID(), session: UUID(), zone: Zone(name: name, yaw: -10...10, pitch: -10...10), pose: Pose())
    }
    func confirmZone(_ draft: ZoneDraft) async throws {}
    func cancelZone(_ draft: ZoneDraft) async {}
}
@Test func logicFormatsStatusAndRejectsInvalidDeltas() throws {
    let state = GimbalStatus(connected: true, referenceReady: false,
        battery: BatteryStatus(percent: 70, charging: true),
        pose: Pose(yaw: 1, pitch: -2, roll: 0.5), lease: nil)
    let text = ShortcutActionLogic.statusText(state)
    #expect(text.contains("Conectada") && text.contains("70%"))
    #expect(text.contains("yaw 1.0") && text.contains("pitch -2.0"))
    #expect(throws: ShortcutActionError.invalidRelativeMove) {
        try ShortcutActionLogic.relativeTarget(from: Pose(), yaw: 15.01, pitch: 0)
    }
    #expect(throws: ShortcutActionError.invalidRelativeMove) {
        try ShortcutActionLogic.relativeTarget(from: Pose(), yaw: .nan, pitch: 0)
    }
}
@Test func serviceUsesZoneAndRejectsOfflineMovement() async throws {
    let runtime = FakeShortcutRuntime()
    let actions = ShortcutActionService(runtime: runtime)
    _ = try await actions.look(zone: "mesa")
    #expect(await runtime.lookedAt == "mesa")
    #expect(await runtime.requestedTimeout == 10)
    #expect(try await actions.moveALittle(yaw: 2, pitch: -1) == Pose(yaw: 3, pitch: 1))
    await actions.stop()
    #expect(await runtime.stopped)
    await runtime.setConnected(false)
    await #expect(throws: ShortcutActionError.connectionUnavailable) {
        _ = try await actions.look(zone: "mesa")
    }
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter 'logicFormatsStatusAndRejectsInvalidDeltas|serviceUsesZoneAndRejectsOfflineMovement'`
Expected: no existen el servicio independiente ni el adaptador del runtime.

- [ ] **Step 3: Implementar**

`Sources/GimbalKitIntents/ShortcutActionService.swift`:
```swift
import Foundation
import GimbalKit
import GimbalHostSupport

public enum ShortcutActionError: Error, Sendable, Equatable, LocalizedError {
    case connectionUnavailable, invalidRelativeMove, zoneNotFound
    public var errorDescription: String? {
        switch self {
        case .connectionUnavailable: return "No se pudo conectar con el estabilizador en 10 segundos. Abre GimbalKit e inténtalo de nuevo."
        case .invalidRelativeMove: return "El movimiento debe ser finito y no superar 15° por eje."
        case .zoneNotFound: return "La zona no existe o no está permitida."
        }
    }
}
public protocol ShortcutActionRuntime: Sendable {
    func start() async throws
    func status() async throws -> GimbalStatus
    func zones() async -> [ZoneRecord]
    func waitUntilConnected(timeout: Double) async throws -> Bool
    func shortcutLook(zone: String) async throws -> GimbalLookResult
    func appLook(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult
    func shortcutMoveRelative(yaw: Double, pitch: Double) async throws -> Pose
    func shortcutStop() async
    func prepareZone(name: String) async throws -> ZoneDraft
    func confirmZone(_ draft: ZoneDraft) async throws
    func cancelZone(_ draft: ZoneDraft) async
}
public enum ShortcutActionLogic {
    public static func statusText(_ value: GimbalStatus) -> String {
        let connection = value.connected ? "Conectada" : "Desconectada"
        let battery = value.battery.map { "batería \($0.percent)%\($0.charging ? ", cargando" : "")" }
            ?? "batería no disponible"
        let pose: String
        if let p = value.pose, p.isFinite {
            pose = String(format: "yaw %.1f°, pitch %.1f°, roll %.1f°", p.yaw, p.pitch, p.roll)
        } else { pose = "pose no disponible" }
        return "\(connection); \(battery); \(pose)"
    }
    public static func relativeTarget(from pose: Pose, yaw: Double, pitch: Double) throws -> Pose {
        guard pose.isFinite, yaw.isFinite, pitch.isFinite, abs(yaw) <= 15,
              abs(pitch) <= 15, yaw != 0 || pitch != 0 else {
            throw ShortcutActionError.invalidRelativeMove
        }
        return Pose(yaw: pose.yaw + yaw, pitch: pose.pitch + pitch, roll: pose.roll)
    }
}
public struct ShortcutActionService: Sendable {
    private let runtime: any ShortcutActionRuntime
    public init(runtime: any ShortcutActionRuntime) { self.runtime = runtime }
    private func connect() async throws {
        try await runtime.start()
        guard try await runtime.waitUntilConnected(timeout: 10) else {
            throw ShortcutActionError.connectionUnavailable
        }
    }
    public func status() async throws -> String {
        try await runtime.start()
        _ = try await runtime.waitUntilConnected(timeout: 10)
        return ShortcutActionLogic.statusText(try await runtime.status())
    }
    public func look(zone: String) async throws -> String {
        try await connect()
        guard await runtime.zones().contains(where: { $0.name == zone && !$0.forbidden }) else {
            throw ShortcutActionError.zoneNotFound
        }
        let result = try await runtime.shortcutLook(zone: zone)
        return "Llegada a \(zone), yaw \(String(format: "%.1f", result.arrivalPose.yaw))°."
    }
    public func moveALittle(yaw: Double, pitch: Double) async throws -> Pose {
        _ = try ShortcutActionLogic.relativeTarget(from: Pose(), yaw: yaw, pitch: pitch)
        try await connect()
        return try await runtime.shortcutMoveRelative(yaw: yaw, pitch: pitch)
    }
    public func stop() async { await runtime.shortcutStop() }
    public func prepareZone(name: String) async throws -> ZoneDraft {
        try await connect()
        return try await runtime.prepareZone(name: name)
    }
    public func confirmZone(_ draft: ZoneDraft) async throws { try await runtime.confirmZone(draft) }
    public func cancelZone(_ draft: ZoneDraft) async { await runtime.cancelZone(draft) }
    public func entityNames() async throws -> [String] {
        try await runtime.start()
        return await runtime.zones().filter { !$0.forbidden }.map(\.name).sorted()
    }
}
```

`Sources/GimbalKitIntents/HostShortcutRuntime.swift`:
```swift
import GimbalHostSupport
import GimbalKit

public struct HostShortcutRuntime: ShortcutActionRuntime {
    private let runtime: HostRuntime
    public init(runtime: HostRuntime) { self.runtime = runtime }
    public func start() async throws { try await runtime.start() }
    public func status() async throws -> GimbalStatus { try await runtime.status() }
    public func zones() async -> [ZoneRecord] { await runtime.zones() }
    public func waitUntilConnected(timeout: Double) async throws -> Bool {
        try await runtime.waitUntilConnected(timeout: timeout)
    }
    public func shortcutLook(zone: String) async throws -> GimbalLookResult {
        try await runtime.shortcutLook(zone: zone)
    }
    public func appLook(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult {
        try await runtime.appLook(zone: zone, leaseSeconds: leaseSeconds)
    }
    public func shortcutMoveRelative(yaw: Double, pitch: Double) async throws -> Pose {
        try await runtime.shortcutMoveRelative(yaw: yaw, pitch: pitch)
    }
    public func shortcutStop() async { await runtime.shortcutStop() }
    public func prepareZone(name: String) async throws -> ZoneDraft {
        try await runtime.prepareZone(name: name)
    }
    public func confirmZone(_ draft: ZoneDraft) async throws { try await runtime.confirmZone(draft) }
    public func cancelZone(_ draft: ZoneDraft) async { await runtime.cancelZone(draft) }
}
```

`Sources/GimbalKitIntents/PhoneShortcutComposition.swift`:
```swift
import GimbalHostSupport

public enum PhoneShortcutComposition {
    public static let actions = ShortcutActionService(
        runtime: HostShortcutRuntime(runtime: PhoneHostComposition.runtime)
    )
}
```

En `Package.swift`, dentro del bloque existente `#if os(macOS)`, añadir este producto, target y test target:
```swift
.library(name: "GimbalKitIntents", targets: ["GimbalKitIntents"]),
```
```swift
.target(name: "GimbalKitIntents", dependencies: ["GimbalKit", "GimbalHostSupport"]),
.testTarget(name: "GimbalKitIntentsTests",
            dependencies: ["GimbalKitIntents", "GimbalHostSupport", "GimbalKit"]),
```

`GimbalKitIntents` depende de `GimbalHostSupport`; `GimbalHostSupport` no depende de intents. En `HostRuntime.swift`, sustituir `look(zone:leaseSeconds:)` y añadir estos miembros completos:
```swift
public func waitUntilConnected(timeout: Double) async throws -> Bool {
    try Task.checkCancellation()
    guard timeout.isFinite, timeout >= 0 else { throw SafetyViolation.invalidDuration }
    if rig != nil { return true }
    let deadline = clock.now().addingTimeInterval(timeout)
    while clock.now() < deadline {
        try Task.checkCancellation()
        if rig != nil { return true }
        let remaining = deadline.timeIntervalSince(clock.now())
        try await clock.sleep(min(0.1, remaining))
    }
    return rig != nil
}
public func look(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult {
    try await performLook(zone: zone, source: .agent("mcp"), leaseSeconds: leaseSeconds)
}
public func shortcutLook(zone: String) async throws -> GimbalLookResult {
    try await performLook(zone: zone, source: .shortcut, leaseSeconds: 30)
}
public func appLook(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult {
    try await performLook(zone: zone, source: .app, leaseSeconds: leaseSeconds)
}
private func performLook(zone: String, source: ControlSource,
                         leaseSeconds: Double) async throws -> GimbalLookResult {
    guard let captured = rig else { throw SafetyViolation.poseUnavailable }
    guard referenceReady else { throw NavigationError.referenceRequired }
    guard leaseSeconds.isFinite, leaseSeconds > 0, leaseSeconds <= 30 else {
        throw SafetyViolation.invalidDuration
    }
    guard !looking, !editing else { throw NavigationError.busy }
    looking = true
    defer { looking = false }
    guard rig?.id == captured.id, referenceReady else { throw NavigationError.interrupted }
    let lease = try await captured.controller.requestLease(
        source: source, zone: zone, seconds: leaseSeconds
    )
    do {
        let arrival = try await captured.navigator.go(to: zone, source: source, lease: lease)
        return GimbalLookResult(status: try await status(), arrivalPose: arrival)
    } catch {
        await captured.controller.release(lease: lease)
        throw error
    }
}
public func shortcutStop() async {
    if let rig { await rig.controller.stop(source: .shortcut) }
}
public func shortcutMoveRelative(yaw: Double, pitch: Double) async throws -> Pose {
    guard yaw.isFinite, pitch.isFinite, abs(yaw) <= 15, abs(pitch) <= 15,
          yaw != 0 || pitch != 0 else { throw SafetyViolation.invalidValue }
    let (captured, current) = try await freshRig()
    guard referenceReady else { throw NavigationError.referenceRequired }
    guard !looking, !editing else { throw NavigationError.busy }
    let target = Pose(yaw: current.yaw + yaw, pitch: current.pitch + pitch, roll: current.roll)
    guard target.isFinite,
          let zone = savedZones.first(where: {
              !$0.forbidden && $0.contains(current) && $0.contains(target)
          }) else { throw NavigationError.unsafePath }
    looking = true
    defer { looking = false }
    guard rig?.id == captured.id, referenceReady else { throw NavigationError.interrupted }
    let lease = try await captured.controller.requestLease(
        source: .shortcut, zone: zone.name, seconds: 15
    )
    do {
        return try await captured.navigator.go(
            to: target, within: zone.name, source: .shortcut, lease: lease
        )
    } catch {
        await captured.controller.release(lease: lease)
        throw error
    }
}
```

En `GotoNavigator.swift`, sustituir el miembro actual `go(to:source:lease:)` e insertar sus overloads/helpers antes de `interruptible(until:operation:)`:
```swift
public func go(to zoneName: String, source: ControlSource, lease: Lease) async throws -> Pose {
    try await navigate(target: nil, zoneName: zoneName, source: source, lease: lease)
}
public func go(to target: Pose, within zoneName: String,
               source: ControlSource, lease: Lease) async throws -> Pose {
    try await navigate(target: target, zoneName: zoneName, source: source, lease: lease)
}
private func navigate(target requestedTarget: Pose?, zoneName: String,
                      source: ControlSource, lease: Lease) async throws -> Pose {
    guard !running else { throw NavigationError.busy }
    guard lease.zone == zoneName, lease.source == source else { throw SafetyViolation.noLease }
    if let requestedTarget, !requestedTarget.isFinite { throw SafetyViolation.invalidValue }
    running = true
    defer { running = false }
    do {
        let deadline = clock.now().addingTimeInterval(limits.timeoutSeconds)
        return try await interruptible(until: deadline) { [self] in
            while true {
                try Task.checkCancellation()
                guard clock.now() < deadline else { throw NavigationError.timeout }
                let initial = try await controller.navigationContext(source: source, lease: lease)
                try await controller.haltNavigation(lease: lease)
                let stoppedAt = clock.now()
                let context = try await settled(after: initial.sample.sequence, stoppedAt: stoppedAt,
                    deadline: deadline, source: source, lease: lease)
                guard context.zone.name == zoneName else { throw NavigationError.interrupted }
                let target: Pose
                if let requestedTarget {
                    target = requestedTarget
                } else {
                    target = Pose(
                        yaw: (context.zone.yaw.lowerBound + context.zone.yaw.upperBound) / 2,
                        pitch: (context.zone.pitch.lowerBound + context.zone.pitch.upperBound) / 2
                    )
                }
                guard context.zone.contains(target),
                      !context.forbidden.contains(where: { $0.contains(target) }) else {
                    throw NavigationError.unsafePath
                }
                let dy = target.yaw - context.sample.pose.yaw
                let dp = target.pitch - context.sample.pose.pitch
                if abs(dy) <= limits.deadband && abs(dp) <= limits.deadband {
                    try Task.checkCancellation()
                    await controller.audit.record(AuditEntry(date: clock.now(), source: source,
                        event: "goto \(zoneName)", outcome: .accepted))
                    try Task.checkCancellation()
                    guard clock.now() < deadline else { throw NavigationError.timeout }
                    return context.sample.pose
                }
                func speed(_ error: Double) -> Double {
                    abs(error) <= limits.deadband ? 0 :
                        max(-limits.maxSpeed, min(limits.maxSpeed, error * limits.gain))
                }
                let velocity = Pose(yaw: speed(dy), pitch: speed(dp))
                guard clock.now().addingTimeInterval(limits.pulseSeconds + limits.brakingSeconds) < deadline else {
                    throw NavigationError.timeout
                }
                try NavigationSafety.check(pose: context.sample.pose, velocity: velocity,
                    zone: context.zone, forbidden: context.forbidden, limits: limits)
                try await controller.navigationPulse(velocity, source: source, lease: lease)
                try await clock.sleep(limits.pulseSeconds)
                try await controller.haltNavigation(lease: lease)
            }
        }
    } catch {
        await controller.release(lease: lease)
        let reason = Task.isCancelled ? "cancelled" :
            String(String(describing: error).prefix { $0 != "(" })
        await controller.audit.record(AuditEntry(date: clock.now(), source: source,
            event: "goto \(zoneName)", outcome: .rejected(reason)))
        if Task.isCancelled { throw CancellationError() }
        throw error
    }
}
```

La zona relativa debe ser permitida y contener pose y destino; el navegador mantiene `NavigationSafety`, asentamiento, deadline, cancelación y liberación de lease.

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: formateo, límites ±15°, desconexión y suite completa pasan sin hardware.

- [ ] **Step 5: Commit** (Claude): `feat: añadir lógica testeable de acciones de Atajos`

---

### Task 3: App Intents, Siri y UI del iPhone

**Files:**
- Create: `Sources/GimbalKitIntents/GimbalKitAppIntents.swift`, `Apps/GimbalPhone/GimbalPhoneApp.swift`, `Apps/GimbalPhone/PhoneHomeView.swift`
- Test: ampliar `Tests/GimbalKitIntentsTests/ShortcutActionServiceTests.swift`

**Interfaces:**
- Consumes: Task 1 `PhoneHostComposition.model`; Task 2 `PhoneShortcutComposition.actions`; `ZoneStore`.
- Produces: `ZoneEntity/AppEntity`, query sobre zonas persistidas, cinco intents, `AppShortcutsProvider` con frases en español; pantalla de estado, zonas, confirmación, navegación, parada y registro.

- [ ] **Step 1: Escribir la prueba que falla**

Añadir al test:
```swift
@Test func entityNamesFilterForbiddenZones() async throws {
    let runtime = FakeShortcutRuntime()
    await runtime.setZones([
        ZoneRecord(Zone(name: "mesa", yaw: -20...20, pitch: -20...20)),
        ZoneRecord(Zone(name: "privada", yaw: 30...40, pitch: -10...10, forbidden: true))
    ])
    #expect(try await ShortcutActionService(runtime: runtime).entityNames() == ["mesa"])
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter entityNamesFilterForbiddenZones`
Expected: no compila porque `FakeShortcutRuntime` todavía no permite configurar zonas.

- [ ] **Step 3: Implementar**

Sustituir el miembro `zones()` de `FakeShortcutRuntime` y añadir el setter:
```swift
private var storedZones: [ZoneRecord] = []
func setZones(_ values: [ZoneRecord]) { storedZones = values }
func zones() async -> [ZoneRecord] { storedZones }
```

`Sources/GimbalKitIntents/GimbalKitAppIntents.swift`:
```swift
#if os(iOS)
import AppIntents
import GimbalHostSupport

public struct ZoneEntity: AppEntity, Identifiable, Sendable {
    public static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Zona")
    public static var defaultQuery = ZoneEntityQuery()
    public let id: String
    public init(id: String) { self.id = id }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}
public struct ZoneEntityQuery: EntityQuery {
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [ZoneEntity] {
        let names = try await PhoneShortcutComposition.actions.entityNames()
        let requested = Set(identifiers)
        return names.filter(requested.contains).map(ZoneEntity.init(id:))
    }
    public func suggestedEntities() async throws -> [ZoneEntity] {
        try await PhoneShortcutComposition.actions.entityNames().map(ZoneEntity.init(id:))
    }
}
public struct LookAtZoneIntent: AppIntent {
    public static var title: LocalizedStringResource = "Mirar a zona"
    public static var openAppWhenRun = true
    @Parameter(title: "Zona") public var zone: ZoneEntity
    public init() {}
    public func perform() async throws -> some IntentResult {
        let value = try await PhoneShortcutComposition.actions.look(zone: zone.id)
        return .result(dialog: IntentDialog(stringLiteral: value))
    }
}
public struct StopGimbalIntent: AppIntent {
    public static var title: LocalizedStringResource = "Parar"
    public static var openAppWhenRun = true
    public init() {}
    public func perform() async throws -> some IntentResult {
        await PhoneShortcutComposition.actions.stop()
        return .result(dialog: "Estabilizador parado.")
    }
}
public struct GimbalStatusIntent: AppIntent {
    public static var title: LocalizedStringResource = "Estado"
    public static var openAppWhenRun = true
    public init() {}
    public func perform() async throws -> some IntentResult {
        let value = try await PhoneShortcutComposition.actions.status()
        return .result(dialog: IntentDialog(stringLiteral: value))
    }
}
public struct MoveGimbalALittleIntent: AppIntent {
    public static var title: LocalizedStringResource = "Mover un poco"
    public static var openAppWhenRun = true
    @Parameter(title: "Yaw relativo en grados", default: 0) public var yaw: Double
    @Parameter(title: "Pitch relativo en grados", default: 0) public var pitch: Double
    public init() {}
    public func perform() async throws -> some IntentResult {
        let target = try await PhoneShortcutComposition.actions.moveALittle(yaw: yaw, pitch: pitch)
        return .result(dialog: "Destino yaw \(target.yaw)°, pitch \(target.pitch)°.")
    }
}
public struct SaveZoneHereIntent: AppIntent {
    public static var title: LocalizedStringResource = "Guardar zona aquí"
    public static var openAppWhenRun = true
    @Parameter(title: "Nombre de la zona") public var name: String
    public init() {}
    public func perform() async throws -> some IntentResult {
        let actions = PhoneShortcutComposition.actions
        let draft = try await actions.prepareZone(name: name)
        let answer = try await requestConfirmation(
            result: .result(dialog: "Guardar \(draft.zone.name) alrededor de la pose actual."),
            dialog: IntentDialog("¿Confirmas que guardemos esta zona?")
        )
        guard answer == .confirmed else {
            await actions.cancelZone(draft)
            return .result(dialog: "No se guardó la zona.")
        }
        try await actions.confirmZone(draft)
        return .result(dialog: "Zona \(draft.zone.name) guardada.")
    }
}
public struct GimbalKitShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LookAtZoneIntent(),
                    phrases: ["Mira a \(\.$zone) con \(.applicationName)"],
                    shortTitle: "Mirar a zona", systemImageName: "camera.aperture"),
        AppShortcut(intent: StopGimbalIntent(),
                    phrases: ["Para el estabilizador con \(.applicationName)"],
                    shortTitle: "Parar", systemImageName: "stop.fill"),
        AppShortcut(intent: GimbalStatusIntent(),
                    phrases: ["Estado del estabilizador con \(.applicationName)"],
                    shortTitle: "Estado", systemImageName: "sensor"),
        AppShortcut(intent: MoveGimbalALittleIntent(),
                    phrases: ["Mueve un poco el estabilizador con \(.applicationName)"],
                    shortTitle: "Mover un poco", systemImageName: "arrow.up.left.and.arrow.down.right"),
        AppShortcut(intent: SaveZoneHereIntent(),
                    phrases: ["Guarda esta zona con \(.applicationName)"],
                    shortTitle: "Guardar zona", systemImageName: "mappin.and.ellipse")
    }
}
#endif
```

`GimbalPhoneApp.swift`:
```swift
import SwiftUI
import GimbalHostSupport
import GimbalKitIntents

@main @MainActor struct GimbalPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            PhoneHomeView(model: PhoneHostComposition.model)
                .task { await PhoneHostComposition.model.start() }
        }
    }
}
```

`PhoneHomeView.swift`:
```swift
import Observation
import SwiftUI
import GimbalKit
import GimbalHostSupport

@MainActor struct PhoneHomeView: View {
    @Bindable var model: PhoneModel
    @State private var name = ""
    @State private var askZone = false
    @State private var askReference = false
    var body: some View {
        NavigationStack {
            List {
                Section("Estabilizador") {
                    Text(model.status.connected ? "Conectada" : "Desconectada · reconectando")
                    if let battery = model.status.battery {
                        Text("Batería: \(battery.percent)%\(battery.charging ? " · cargando" : "")")
                    } else { Text("Batería no disponible") }
                    if let pose = model.status.pose {
                        Text("Yaw \(pose.yaw, specifier: "%.1f")° · Pitch \(pose.pitch, specifier: "%.1f")° · Roll \(pose.roll, specifier: "%.1f")°")
                    } else { Text("Pose no disponible o desactualizada") }
                    Button("PARADA", role: .destructive) { Task { await model.humanStop() } }
                        .font(.title2.bold()).buttonStyle(.borderedProminent).tint(.red)
                        .frame(maxWidth: .infinity).controlSize(.large)
                }
                Section("Zonas") {
                    if !model.status.referenceReady && !model.zones.isEmpty {
                        Text("Confirme la referencia de esta conexión.")
                        Button("Confirmar referencia de zonas") {
                            Task { await model.prepareReference(); askReference = model.referenceDraft != nil }
                        }.disabled(!model.status.connected || model.status.pose == nil)
                    }
                    ForEach(model.zones, id: \.name) { zone in
                        HStack {
                            Text(zone.name); Spacer()
                            Button("Ir a zona") { Task { await model.look(zone: zone.name) } }
                                .disabled(zone.forbidden || !model.status.connected ||
                                          !model.status.referenceReady || model.status.pose == nil)
                        }
                    }
                    TextField("Nombre", text: $name)
                    Button("Guardar zona aquí") {
                        Task { await model.prepareZone(name: name); askZone = model.zoneDraft != nil }
                    }.disabled(model.status.pose == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Registro") {
                    ForEach(Array(model.audit.suffix(40).enumerated()), id: \.offset) { _, row in
                        Text("\(row.date.ISO8601Format()) · \(row.event)").font(.caption.monospaced())
                    }
                }
                if let error = model.errorMessage { Section("Aviso") { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("GimbalKit")
            .refreshable { await model.refresh() }
            .alert("Guardar zona aquí", isPresented: $askZone) {
                Button("Guardar") { Task { await model.confirmZone(); name = "" } }
                Button("Cancelar", role: .cancel) { Task { await model.cancelZone() } }
            } message: {
                if let draft = model.zoneDraft {
                    Text("Crear «\(draft.zone.name)» con ±10° alrededor de yaw \(draft.pose.yaw, specifier: "%.1f")° y pitch \(draft.pose.pitch, specifier: "%.1f")°.")
                }
            }
            .confirmationDialog("Confirmar referencia", isPresented: $askReference) {
                Button("He comprobado las zonas") { Task { await model.confirmReference() } }
                Button("Cancelar", role: .cancel) { Task { await model.cancelReference() } }
            } message: {
                Text("Confirme solo después de comprobar físicamente las zonas guardadas.")
            }
        }
    }
}
```

`requestConfirmation` debe preceder a `confirmZone`; una denegación/cancelación llama `cancelZone`. `ZoneEntityQuery` obtiene nombres de `ZoneStore` por runtime compartido y no incluye zonas prohibidas. Todas las fachadas se compilan con `#if os(iOS)`.

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: el filtro de nombres excluye zonas prohibidas; la build de App Intents/SwiftUI se hará en Task 7.

- [ ] **Step 5: Commit** (Claude): `feat: añadir intents Siri y app anfitriona iOS`

---

### Task 4: Mensajes Watch Codable y codec WCSession

**Files:**
- Create: `Sources/GimbalWatchKit/WatchMessages.swift`, `Tests/GimbalWatchKitTests/WatchMessagesTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: Foundation.
- Produces: comandos `stop`, `look(zone)`, `jog(yaw,pitch,seq,sentAt)`, `status`; `WatchStatus` con conexión/batería/pose redondeada/zonas/lease; replies/eventos/rechazos tipados; codec `[String: Any]`.

- [ ] **Step 1: Escribir la prueba que falla**

`Tests/GimbalWatchKitTests/WatchMessagesTests.swift`:
```swift
import Foundation
import Testing
@testable import GimbalWatchKit

@Test func commandsRoundTripThroughDictionaries() throws {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let values: [WatchCommand] = [
        .stop, .look(zone: "mesa"), .jog(yaw: 4, pitch: -2, seq: 9, sentAt: date), .status
    ]
    for value in values {
        #expect(try WatchWireCodec.command(from: WatchWireCodec.commandDictionary(value)) == value)
    }
}
@Test func malformedAndNonFiniteCommandsFailClosed() throws {
    #expect(throws: WatchWireError.malformed) { try WatchWireCodec.command(from: ["type": "fly"]) }
    #expect(throws: WatchWireError.malformed) {
        _ = try WatchWireCodec.commandDictionary(.jog(yaw: .infinity, pitch: 0, seq: 1, sentAt: Date()))
    }
}
@Test func poseIsRoundedToOneDecimal() {
    #expect(WatchPose(yaw: 2.26, pitch: -1.24, roll: 0).yaw == 2.3)
    #expect(WatchPose(yaw: 2.26, pitch: -1.24, roll: 0).pitch == -1.2)
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter 'commandsRoundTripThroughDictionaries|malformedAndNonFiniteCommandsFailClosed|poseIsRoundedToOneDecimal'`
Expected: no existe producto o codec Watch.

- [ ] **Step 3: Implementar**

`Sources/GimbalWatchKit/WatchMessages.swift`:
```swift
import Foundation

public enum WatchWireError: Error, Sendable, Equatable { case malformed }
public enum WatchCommand: Sendable, Equatable, Codable {
    case stop, status
    case look(zone: String)
    case jog(yaw: Double, pitch: Double, seq: UInt64, sentAt: Date)
    private enum Key: String, CodingKey { case type, zone, yaw, pitch, seq, sentAt }
    private enum Kind: String, Codable { case stop, status, look, jog }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .stop: self = .stop
        case .status: self = .status
        case .look: self = .look(zone: try c.decode(String.self, forKey: .zone))
        case .jog:
            self = .jog(yaw: try c.decode(Double.self, forKey: .yaw),
                        pitch: try c.decode(Double.self, forKey: .pitch),
                        seq: try c.decode(UInt64.self, forKey: .seq),
                        sentAt: try c.decode(Date.self, forKey: .sentAt))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .stop: try c.encode(Kind.stop, forKey: .type)
        case .status: try c.encode(Kind.status, forKey: .type)
        case let .look(zone):
            try c.encode(Kind.look, forKey: .type); try c.encode(zone, forKey: .zone)
        case let .jog(yaw, pitch, seq, date):
            guard yaw.isFinite, pitch.isFinite else { throw WatchWireError.malformed }
            try c.encode(Kind.jog, forKey: .type); try c.encode(yaw, forKey: .yaw)
            try c.encode(pitch, forKey: .pitch); try c.encode(seq, forKey: .seq)
            try c.encode(date, forKey: .sentAt)
        }
    }
}
public struct WatchPose: Sendable, Codable, Equatable {
    public let yaw: Double; public let pitch: Double; public let roll: Double
    public init(yaw: Double, pitch: Double, roll: Double) {
        self.yaw = (yaw * 10).rounded() / 10
        self.pitch = (pitch * 10).rounded() / 10
        self.roll = (roll * 10).rounded() / 10
    }
}
public struct WatchLease: Sendable, Codable, Equatable {
    public let zone: String; public let remainingSeconds: Double
    public init(zone: String, remainingSeconds: Double) {
        self.zone = zone; self.remainingSeconds = remainingSeconds
    }
}
public struct WatchStatus: Sendable, Codable, Equatable {
    public let connected: Bool; public let batteryPercent: Int?
    public let pose: WatchPose?; public let zones: [String]; public let lease: WatchLease?
    public init(connected: Bool, batteryPercent: Int?, pose: WatchPose?, zones: [String], lease: WatchLease?) {
        self.connected = connected; self.batteryPercent = batteryPercent
        self.pose = pose; self.zones = zones; self.lease = lease
    }
}
public enum WatchRejection: String, Sendable, Codable, Equatable {
    case malformed, staleCommand, outOfOrder, speedLimit, invalidValue
    case zoneNotFound, forbiddenZone, busy, notReachable, policyRejected
}
public enum WatchReply: Sendable, Codable, Equatable {
    case accepted, status(WatchStatus), rejected(WatchRejection)
}
public enum WatchEvent: Sendable, Codable, Equatable { case arrived, stopped, lookFailed }

public enum WatchWireCodec {
    private static func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WatchWireError.malformed
        }
        return dict
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ dict: [String: Any]) throws -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(type, from: data)
        } catch { throw WatchWireError.malformed }
    }
    public static func commandDictionary(_ value: WatchCommand) throws -> [String: Any] { try encode(value) }
    public static func command(from dict: [String: Any]) throws -> WatchCommand { try decode(WatchCommand.self, dict) }
    public static func replyDictionary(_ value: WatchReply) throws -> [String: Any] { try encode(value) }
    public static func reply(from dict: [String: Any]) throws -> WatchReply { try decode(WatchReply.self, dict) }
    public static func eventDictionary(_ value: WatchEvent) throws -> [String: Any] { try encode(value) }
    public static func event(from dict: [String: Any]) throws -> WatchEvent { try decode(WatchEvent.self, dict) }
}
```

En `Package.swift`, añadir watchOS 10 a la lista de plataformas. Dentro de `#if os(macOS)`, añadir estos productos y targets; `GimbalKitSim` queda disponible para el reloj simulado de la siguiente tarea:
```swift
.library(name: "GimbalWatchKit", targets: ["GimbalWatchKit"]),
```
```swift
.target(name: "GimbalWatchKit", dependencies: ["GimbalKit"]),
.testTarget(name: "GimbalWatchKitTests",
            dependencies: ["GimbalWatchKit", "GimbalKit", "GimbalKitSim"]),
```
Mensajes/codec solo importan Foundation. El target Watch no depende de host ni BLE.

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: mensajes round-trip, errores malformados tipados y redondeo verificado.

- [ ] **Step 5: Commit** (Claude): `feat: definir protocolo Codable de Apple Watch`

---

### Task 5: PhoneWatchService, deadman y stop prioritario

**Files:**
- Create: `Sources/GimbalWatchKit/PhoneWatchService.swift`, `Sources/GimbalWatchKit/HostWatchRuntime.swift`, `Tests/GimbalWatchKitTests/PhoneWatchServiceTests.swift`
- Modify: `Package.swift`, `Sources/GimbalKit/GimbalController.swift`, `Sources/GimbalHostSupport/HostRuntime.swift`
- Test: `Tests/GimbalKitTests/WatchStopPriorityTests.swift`

**Interfaces:**
- Consumes: Task 4 mensajes; `GimbalController`, `HostRuntime`, reloj inyectado.
- Produces: `WatchRuntime`, servicio actor; jog ≤12°/s, timestamp ≤0,6 s, secuencia creciente, cadence ≥0,25 s, deadman 0,6 s; look con lease `.app`; reachability perdida = stop inmediato; cola del controlador prioriza stop.

- [ ] **Step 1: Escribir las pruebas que fallan**

`Tests/GimbalWatchKitTests/PhoneWatchServiceTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit
import GimbalKitSim
@testable import GimbalWatchKit

actor FakeWatchRuntime: WatchRuntime {
    private(set) var speeds: [(Double, Double)] = []
    private(set) var stops = 0
    private(set) var looks: [String] = []
    func status() async throws -> GimbalStatus {
        GimbalStatus(connected: true, referenceReady: true, battery: nil, pose: Pose(), lease: nil)
    }
    func zones() async -> [ZoneRecord] {
        [ZoneRecord(Zone(name: "mesa", yaw: -30...30, pitch: -20...20))]
    }
    func watchLook(zone: String) async throws -> Pose { looks.append(zone); return Pose() }
    func watchJog(yaw: Double, pitch: Double) async throws { speeds.append((yaw, pitch)) }
    func watchStop() async { stops += 1 }
}
actor BlockingZonesRuntime: WatchRuntime {
    private(set) var zoneReadStarted = false
    private(set) var looks = 0
    private(set) var stops = 0
    private var continuation: CheckedContinuation<[ZoneRecord], Never>?
    func status() async throws -> GimbalStatus {
        GimbalStatus(connected: true, referenceReady: true, battery: nil, pose: Pose(), lease: nil)
    }
    func zones() async -> [ZoneRecord] {
        zoneReadStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func releaseZones() {
        continuation?.resume(returning: [ZoneRecord(Zone(name: "mesa", yaw: -20...20, pitch: -20...20))])
        continuation = nil
    }
    func watchLook(zone: String) async throws -> Pose { looks += 1; return Pose() }
    func watchJog(yaw: Double, pitch: Double) async throws {}
    func watchStop() async { stops += 1 }
}
@Test func stopDuringZoneLookupCannotStartLateLook() async throws {
    let runtime = BlockingZonesRuntime()
    let service = PhoneWatchService(runtime: runtime)
    let look = Task { await service.receive(.look(zone: "mesa")) }
    while !(await runtime.zoneReadStarted) { await Task.yield() }
    #expect(await service.receive(.stop) == .accepted)
    await runtime.releaseZones()
    #expect(await look.value == .rejected(.busy))
    #expect(await runtime.looks == 0)
    #expect(await runtime.stops == 1)
}
@Test func jogAgeCadenceAndDeadmanHaveExactBounds() {
    let start = Date(timeIntervalSince1970: 100)
    #expect(WatchJogSafety.timestampIsValid(sentAt: start, now: start.addingTimeInterval(0.6)))
    #expect(!WatchJogSafety.timestampIsValid(sentAt: start, now: start.addingTimeInterval(0.61)))
    #expect(!WatchJogSafety.cadenceReady(now: start.addingTimeInterval(0.249), lastSent: start))
    #expect(WatchJogSafety.cadenceReady(now: start.addingTimeInterval(0.25), lastSent: start))
    #expect(!WatchJogSafety.deadmanExpired(now: start.addingTimeInterval(0.59), lastJog: start))
    #expect(WatchJogSafety.deadmanExpired(now: start.addingTimeInterval(0.6), lastJog: start))
}
@Test func invalidSequenceAgeSpeedAndZoneDoNotMove() async throws {
    let runtime = FakeWatchRuntime(), clock = ManualClock()
    let service = PhoneWatchService(runtime: runtime, clock: RuntimeClock(
        now: { clock.now() }, sleep: { _ in throw CancellationError() }
    ))
    let now = clock.now()
    #expect(await service.receive(.jog(yaw: 2, pitch: 0, seq: 1, sentAt: now)) == .accepted)
    #expect(await service.receive(.jog(yaw: 2, pitch: 0, seq: 1, sentAt: now)) == .rejected(.outOfOrder))
    #expect(await service.receive(.jog(yaw: 2, pitch: 0, seq: 2, sentAt: now.addingTimeInterval(-0.61))) == .rejected(.staleCommand))
    #expect(await service.receive(.jog(yaw: 13, pitch: 0, seq: 2, sentAt: now)) == .rejected(.speedLimit))
    #expect(await service.receive(.jog(yaw: .nan, pitch: 0, seq: 2, sentAt: now)) == .rejected(.invalidValue))
    #expect(await service.receive(.look(zone: "fantasma")) == .rejected(.zoneNotFound))
    #expect(await runtime.looks.isEmpty)
    #expect(await runtime.speeds.count <= 1)
}
@Test func jogDeadmanStopsOnInjectedClock() async throws {
    let runtime = FakeWatchRuntime(), clock = ManualClock()
    let service = PhoneWatchService(runtime: runtime, clock: RuntimeClock(
        now: { clock.now() }, sleep: { seconds in clock.advance(seconds) }
    ))
    let start = clock.now()
    #expect(await service.receive(.jog(yaw: 2, pitch: 0, seq: 1, sentAt: start)) == .accepted)
    for _ in 0..<10_000 {
        if await runtime.stops > 0 { break }
        await Task.yield()
    }
    #expect(await runtime.stops >= 1)
    #expect(clock.now().timeIntervalSince(start) <= 0.65)
}
@Test func losingReachabilityDuringJogCallsStop() async throws {
    let runtime = FakeWatchRuntime()
    let service = PhoneWatchService(runtime: runtime)
    #expect(await service.receive(.jog(yaw: 2, pitch: 0, seq: 1, sentAt: Date())) == .accepted)
    await service.setReachable(false)
    #expect(await runtime.stops == 1)
}
```

`Tests/GimbalKitTests/WatchStopPriorityTests.swift`:
```swift
import Foundation
import Testing
@testable import GimbalKit
import GimbalKitSim

private actor BlockingDevice: GimbalDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    private(set) var commands: [MoveCommand] = []
    private(set) var waiting = false
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    func currentPose() -> Pose? { Pose() }
    func send(_ command: MoveCommand) async throws {
        if case .speed = command, !blocked {
            blocked = true
            waiting = true
            await withCheckedContinuation { continuation = $0 }
            waiting = false
        }
        commands.append(command)
    }
    func open() { continuation?.resume(); continuation = nil }
}

@Test func queuedOldSpeedsCannotRunAfterPriorityStop() async throws {
    let device = BlockingDevice()
    let controller = GimbalController(device: device, policy: makePolicy())
    let lease = try await controller.requestLease(source: .agent("watch-test"), zone: "mesa", seconds: 10)
    let first = Task {
        try await controller.send(.speed(yaw: 1, pitch: 0, roll: 0), source: lease.source, lease: lease)
    }
    while !(await device.waiting) { await Task.yield() }
    let second = Task {
        try await controller.send(.speed(yaw: 2, pitch: 0, roll: 0), source: lease.source, lease: lease)
    }
    while await controller.queuedJobsForTesting == 0 { await Task.yield() }
    let stopping = Task { await controller.stop(source: .app) }
    while await controller.activeLease != nil { await Task.yield() }
    await device.open()
    _ = try? await first.value
    _ = try? await second.value
    await stopping.value
    #expect(await device.commands == [.speed(yaw: 1, pitch: 0, roll: 0), .stop])
}

@Test func watchAppSourceStillUsesSafetyPolicySpeedLimit() async throws {
    let sim = SimGimbal()
    var policy = makePolicy()
    policy.maxSpeed = 6
    let controller = GimbalController(device: sim, policy: policy)
    await #expect(throws: SafetyViolation.speedTooHigh(limit: 6, requested: 7)) {
        try await controller.send(.speed(yaw: 7, pitch: 0, roll: 0), source: .app)
    }
    #expect(await sim.commands.isEmpty)
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter 'invalidSequenceAgeSpeedAndZoneDoNotMove|jogDeadmanStopsOnInjectedClock|losingReachabilityDuringJogCallsStop|stopDuringZoneLookupCannotStartLateLook|WatchStopPriorityTests'`
Expected: no existe el servicio y la cola actual no declara prioridad de STOP.

- [ ] **Step 3: Implementar**

`Sources/GimbalWatchKit/PhoneWatchService.swift` (compilar para iOS/macOS, no watchOS):
```swift
#if os(iOS) || os(macOS)
import Foundation
import GimbalKit

public protocol WatchRuntime: Sendable {
    func status() async throws -> GimbalStatus
    func zones() async -> [ZoneRecord]
    func watchLook(zone: String) async throws -> Pose
    func watchJog(yaw: Double, pitch: Double) async throws
    func watchStop() async
}
enum WatchJogSafety {
    static func timestampIsValid(sentAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(sentAt)
        return age >= 0 && age <= 0.6
    }
    static func cadenceReady(now: Date, lastSent: Date?) -> Bool {
        guard let lastSent else { return true }
        return now.timeIntervalSince(lastSent) >= 0.25
    }
    static func deadmanExpired(now: Date, lastJog: Date) -> Bool {
        now.timeIntervalSince(lastJog) >= 0.6
    }
}
public actor PhoneWatchService {
    private let runtime: any WatchRuntime
    private let clock: RuntimeClock
    private let onEvent: @Sendable (WatchEvent) -> Void
    private var reachable = true
    private var lastSequence: UInt64?
    private var lastJog: (yaw: Double, pitch: Double, received: Date)?
    private var lastSent: Date?
    private var generation: UInt64 = 0
    private var jogTask: Task<Void, Never>?
    private var deadmanTask: Task<Void, Never>?
    private var lookTask: Task<Void, Never>?
    private var moving = false
    public init(runtime: any WatchRuntime, clock: RuntimeClock = .live,
                onEvent: @escaping @Sendable (WatchEvent) -> Void = { _ in }) {
        self.runtime = runtime; self.clock = clock; self.onEvent = onEvent
    }
    public func receive(_ command: WatchCommand) async -> WatchReply {
        switch command {
        case .stop:
            await stopNow()
            return .accepted
        case .status:
            guard let state = try? await runtime.status() else {
                return .status(WatchStatus(connected: false, batteryPercent: nil, pose: nil, zones: [], lease: nil))
            }
            let records = await runtime.zones()
            let pose = state.pose.flatMap { $0.isFinite ? WatchPose(yaw: $0.yaw, pitch: $0.pitch, roll: $0.roll) : nil }
            let lease = state.lease.map { WatchLease(zone: $0.zone, remainingSeconds: $0.remainingSeconds) }
            return .status(WatchStatus(connected: state.connected, batteryPercent: state.battery?.percent,
                pose: pose, zones: records.filter { !$0.forbidden }.map(\.name).sorted(), lease: lease))
        case let .look(zone):
            guard reachable else { return .rejected(.notReachable) }
            guard !moving else { return .rejected(.busy) }
            let beforeLookup = generation
            let records = await runtime.zones()
            guard generation == beforeLookup else { return .rejected(.busy) }
            guard reachable else { return .rejected(.notReachable) }
            guard !moving else { return .rejected(.busy) }
            guard let item = records.first(where: { $0.name == zone }) else {
                return .rejected(.zoneNotFound)
            }
            guard !item.forbidden else { return .rejected(.forbiddenZone) }
            lookTask?.cancel(); generation &+= 1
            let current = generation, runtime = self.runtime
            moving = true
            lookTask = Task { [weak self] in
                do {
                    _ = try await runtime.watchLook(zone: zone)
                    await self?.lookFinished(current, arrived: true)
                } catch { await self?.lookFinished(current, arrived: false) }
            }
            return .accepted
        case let .jog(yaw, pitch, seq, sentAt):
            guard yaw.isFinite, pitch.isFinite, yaw != 0 || pitch != 0 else { return .rejected(.invalidValue) }
            guard abs(yaw) <= 12, abs(pitch) <= 12 else { return .rejected(.speedLimit) }
            guard WatchJogSafety.timestampIsValid(sentAt: sentAt, now: clock.now()) else {
                return .rejected(.staleCommand)
            }
            if let lastSequence, seq <= lastSequence { return .rejected(.outOfOrder) }
            guard reachable else { return .rejected(.notReachable) }
            guard lookTask == nil else { return .rejected(.busy) }
            lastSequence = seq; lastJog = (yaw, pitch, clock.now()); moving = true
            if jogTask == nil {
                generation &+= 1
                let current = generation
                jogTask = Task { [weak self] in await self?.runJog(current) }
                deadmanTask = Task { [weak self] in await self?.monitorDeadman(current) }
            }
            return .accepted
        }
    }
    public func setReachable(_ value: Bool) async {
        reachable = value
        if !value, moving { await stopNow() }
    }
    private func runJog(_ current: UInt64) async {
        defer { if generation == current { jogTask = nil } }
        while !Task.isCancelled, generation == current {
            guard reachable, let jog = lastJog else { await stopNow(); return }
            guard !WatchJogSafety.deadmanExpired(now: clock.now(), lastJog: jog.received) else {
                await stopNow(); return
            }
            if WatchJogSafety.cadenceReady(now: clock.now(), lastSent: lastSent) {
                do {
                    try await runtime.watchJog(yaw: jog.yaw, pitch: jog.pitch)
                    guard generation == current else { return }
                    lastSent = clock.now()
                } catch {
                    if generation == current { await stopNow() }
                    return
                }
            }
            do { try await clock.sleep(0.05) } catch {
                if !Task.isCancelled, generation == current { await stopNow() }
                return
            }
        }
    }
    private func monitorDeadman(_ current: UInt64) async {
        defer { if generation == current { deadmanTask = nil } }
        while !Task.isCancelled, generation == current {
            guard reachable, let jog = lastJog else { await stopNow(); return }
            guard !WatchJogSafety.deadmanExpired(now: clock.now(), lastJog: jog.received) else {
                await stopNow(); return
            }
            do { try await clock.sleep(0.05) } catch {
                if !Task.isCancelled, generation == current { await stopNow() }
                return
            }
        }
    }
    private func lookFinished(_ current: UInt64, arrived: Bool) {
        guard generation == current else { return }
        lookTask = nil; moving = false
    }
    private func stopNow() async {
        generation &+= 1
        let oldJog = jogTask, oldDeadman = deadmanTask, oldLook = lookTask
        jogTask = nil; deadmanTask = nil; lookTask = nil; lastJog = nil; moving = false
        oldJog?.cancel(); oldDeadman?.cancel(); oldLook?.cancel()
        await runtime.watchStop()
        onEvent(.stopped)
    }
}
#endif
```

`Sources/GimbalWatchKit/HostWatchRuntime.swift`:
```swift
#if os(iOS) || os(macOS)
import GimbalHostSupport
import GimbalKit

public struct HostWatchRuntime: WatchRuntime {
    private let runtime: HostRuntime
    public init(runtime: HostRuntime) { self.runtime = runtime }
    public func status() async throws -> GimbalStatus { try await runtime.status() }
    public func zones() async -> [ZoneRecord] { await runtime.zones() }
    public func watchLook(zone: String) async throws -> Pose {
        try await runtime.start()
        guard try await runtime.waitUntilConnected(timeout: 10) else {
            throw SafetyViolation.poseUnavailable
        }
        try Task.checkCancellation()
        let result = try await runtime.appLook(zone: zone, leaseSeconds: 30)
        return result.arrivalPose
    }
    public func watchJog(yaw: Double, pitch: Double) async throws {
        try await runtime.start()
        try await runtime.watchJog(yaw: yaw, pitch: pitch)
    }
    public func watchStop() async { await runtime.humanStop() }
}
#endif
```

En `Package.swift`, sustituir la entrada de `GimbalWatchKit` y la del test target por:
```swift
.target(name: "GimbalWatchKit", dependencies: [
    "GimbalKit",
    .target(name: "GimbalHostSupport", condition: .when(platforms: [.iOS, .macOS]))
]),
.testTarget(name: "GimbalWatchKitTests",
            dependencies: ["GimbalWatchKit", "GimbalHostSupport", "GimbalKit", "GimbalKitSim"]),
```

Añadir a `HostRuntime`:
```swift
public func watchJog(yaw: Double, pitch: Double) async throws {
    try Task.checkCancellation()
    guard yaw.isFinite, pitch.isFinite else { throw SafetyViolation.invalidValue }
    guard let captured = rig else { throw SafetyViolation.poseUnavailable }
    guard !editing else { throw NavigationError.busy }
    let activeLease = await captured.controller.activeLease
    try Task.checkCancellation()
    if looking || activeLease != nil {
        await captured.controller.stop(source: .app)
    }
    try Task.checkCancellation()
    guard rig?.id == captured.id else { throw NavigationError.interrupted }
    try await captured.controller.send(.speed(yaw: yaw, pitch: pitch, roll: 0), source: .app)
}
```

El controlador valida el máximo de política para `.app`; no recortar velocidad ni saltarse `GimbalController`.

En `GimbalController.swift`, añadir este miembro para sincronizar la prueba sin pausas reales:
```swift
var queuedJobsForTesting: Int { jobs.count }
```

Sustituir `release(lease:)`, `stop(source:)`, `revokeLease(reason:)` y `enqueue(_:)` por estos miembros:
```swift
public func release(lease presented: Lease) async {
    guard lease?.id == presented.id else { return }
    invalidate()
    try? await enqueue(.stop, priority: true)
    await record(presented.source, "lease released", .accepted)
}
public func stop(source: ControlSource) async {
    epoch &+= 1
    movingBySpeed = false
    lastSpeedAt = nil
    if source.isPrivileged || lease?.source == source { lease = nil }
    try? await enqueue(.stop, priority: true)
    await record(source, "stop", .accepted)
}
func revokeLease(reason: String) async {
    let source = lease?.source
    invalidate()
    try? await enqueue(.stop, priority: true)
    await record(source, "lease revoked: \(reason)", .accepted)
}
private func enqueue(_ command: MoveCommand, priority: Bool = false) async throws {
    try await withCheckedThrowingContinuation { continuation in
        let job = Job(command: command, epoch: epoch, completion: continuation)
        if priority || command == .stop { jobs.insert(job, at: 0) } else { jobs.append(job) }
        if !pumping { pumping = true; Task { await self.pump() } }
    }
}
```

El `pump()` existente mantiene su regla: descarta jobs que no son `.stop` si su epoch difiere. El target `GimbalWatchKit` depende de `GimbalHostSupport` solo en iOS/macOS; en watchOS solo compila mensajes/codec.

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: seq, antigüedad, valores no finitos, zona, reachability, policy max speed, STOP prioritario, cadence exacta de 0,25 s y deadman de 0,6 s pasan. Nada de esperas de pared en pruebas.

- [ ] **Step 5: Commit** (Claude): `feat: proteger los mandos Watch con stop prioritario y deadman`

---

### Task 6: UI Watch y transporte entre reloj e iPhone

**Files:**
- Create: `Apps/GimbalPhone/PhoneWatchBridge.swift`, `Apps/GimbalWatch/GimbalWatchApp.swift`, `Apps/GimbalWatch/WatchHomeView.swift`
- Modify: `Apps/GimbalPhone/GimbalPhoneApp.swift`
- Test: ampliar `Tests/GimbalWatchKitTests/PhoneWatchServiceTests.swift`

**Interfaces:**
- Consumes: `PhoneWatchService`, `HostWatchRuntime`, `WatchWireCodec`, `WCSession`.
- Produces: PARADA grande, zonas, corona, estado, háptica llegada/parada; jog en cada giro y STOP tras 0,3 s de inactividad de la corona; bridge phone reenvía reachability y eventos.

- [ ] **Step 1: Escribir la prueba que falla**

Añadir actor `EventRecorder` y test de look completado:
```swift
actor EventRecorder {
    private(set) var values: [WatchEvent] = []
    func append(_ value: WatchEvent) { values.append(value) }
}
func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
@Test func completedLookSendsArrivalEvent() async throws {
    let recorder = EventRecorder()
    let service = PhoneWatchService(runtime: FakeWatchRuntime(), clock: .live) { value in
        Task { await recorder.append(value) }
    }
    #expect(await service.receive(.look(zone: "mesa")) == .accepted)
    #expect(await eventually { await recorder.values.contains(.arrived) })
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter completedLookSendsArrivalEvent`
Expected: no se ha verificado el evento al terminar el look.

- [ ] **Step 3: Implementar**

En `PhoneWatchService`, sustituir el miembro completo:
```swift
private func lookFinished(_ current: UInt64, arrived: Bool) {
    guard generation == current else { return }
    lookTask = nil
    moving = false
    onEvent(arrived ? .arrived : .lookFailed)
}
```

`Apps/GimbalPhone/PhoneWatchBridge.swift`:
```swift
import Foundation
@preconcurrency import WatchConnectivity
import GimbalHostSupport
import GimbalWatchKit

@MainActor final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchBridge()
    private var service: PhoneWatchService?
    func activate() {
        guard WCSession.isSupported() else { return }
        Task { try? await PhoneHostComposition.runtime.start() }
        service = PhoneWatchService(runtime: HostWatchRuntime(runtime: PhoneHostComposition.runtime)) { event in
            Task { @MainActor in
                guard let value = try? WatchWireCodec.eventDictionary(event) else { return }
                WCSession.default.transferUserInfo(value)
            }
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { await service?.setReachable(session.isReachable) }
    }
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { await service?.setReachable(session.isReachable) }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            guard let service else {
                replyHandler((try? WatchWireCodec.replyDictionary(.rejected(.notReachable))) ?? [:]); return
            }
            guard let command = try? WatchWireCodec.command(from: message) else {
                replyHandler((try? WatchWireCodec.replyDictionary(.rejected(.malformed))) ?? [:]); return
            }
            try? await PhoneHostComposition.runtime.start()
            let answer = await service.receive(command)
            replyHandler((try? WatchWireCodec.replyDictionary(answer)) ?? [:])
        }
    }
}
```

`Apps/GimbalWatch/GimbalWatchApp.swift`:
```swift
import SwiftUI
@main @MainActor struct GimbalWatchApp: App {
    @State private var model = WatchModel()
    var body: some Scene { WindowGroup { WatchHomeView(model: model) } }
}
```

`Apps/GimbalWatch/WatchHomeView.swift`:
```swift
import Foundation
import Observation
import SwiftUI
import WatchKit
@preconcurrency import WatchConnectivity
import GimbalWatchKit

@MainActor @Observable final class WatchModel: NSObject, WCSessionDelegate {
    var status = WatchStatus(connected: false, batteryPercent: nil, pose: nil, zones: [], lease: nil)
    var message = "Conecta con el iPhone"
    private var sequence = UInt64(UserDefaults.standard.integer(forKey: "gimbalkit.watch.sequence"))
    private var releaseTask: Task<Void, Never>?
    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
    func refresh() { send(.status) }
    func stop() {
        releaseTask?.cancel()
        send(.stop) { _ in WKInterfaceDevice.current().play(.click) }
    }
    func look(_ zone: String) { send(.look(zone: zone)) }
    func crownChanged(_ value: Double) {
        let speed = max(-6, min(6, value))
        guard speed != 0 else { stop(); return }
        sequence &+= 1
        UserDefaults.standard.set(Int64(sequence), forKey: "gimbalkit.watch.sequence")
        send(.jog(yaw: speed, pitch: 0, seq: sequence, sentAt: Date()))
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await MainActor.run { self?.stop() }
        }
    }
    private func send(_ command: WatchCommand, completion: ((WatchReply) -> Void)? = nil) {
        guard WCSession.default.isReachable,
              let values = try? WatchWireCodec.commandDictionary(command) else {
            message = "iPhone no alcanzable"; return
        }
        WCSession.default.sendMessage(values, replyHandler: { [weak self] values in
            guard let reply = try? WatchWireCodec.reply(from: values) else { return }
            Task { @MainActor in
                switch reply {
                case let .status(state): self?.status = state
                case let .rejected(reason): self?.message = "Orden rechazada: \(reason)"
                case .accepted: break
                }
                completion?(reply)
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.message = "No se pudo enviar" }
        })
    }
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        refresh()
    }
    func session(_ session: WCSession, didReceiveMessage values: [String: Any]) { receive(values) }
    func session(_ session: WCSession, didReceiveUserInfo values: [String: Any]) { receive(values) }
    private func receive(_ values: [String: Any]) {
        if let event = try? WatchWireCodec.event(from: values) {
            switch event {
            case .arrived: WKInterfaceDevice.current().play(.success); message = "Llegada"
            case .stopped: WKInterfaceDevice.current().play(.click); message = "Parado"
            case .lookFailed: message = "No se pudo completar la mirada"
            }
        }
        if let reply = try? WatchWireCodec.reply(from: values), case let .status(state) = reply {
            status = state
        }
    }
}
@MainActor struct WatchHomeView: View {
    @Bindable var model: WatchModel
    @State private var crown = 0.0
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Button("PARADA", role: .destructive) { model.stop() }
                    .font(.headline.bold()).buttonStyle(.borderedProminent).tint(.red)
                Text(model.status.connected ? "iPhone conectado" : "Sin conexión")
                if let battery = model.status.batteryPercent { Text("Batería \(battery)%") }
                if let pose = model.status.pose {
                    Text("Yaw \(pose.yaw, specifier: "%.1f")° · Pitch \(pose.pitch, specifier: "%.1f")°")
                }
                if let lease = model.status.lease { Text("Control: \(lease.zone)") }
                ForEach(model.status.zones, id: \.self) { zone in
                    Button("Mirar a \(zone)") { model.look(zone) }
                }
                Text("Corona: mover yaw")
                    .digitalCrownRotation($crown, from: -6, through: 6, by: 0.5,
                        sensitivity: .low, isContinuous: true, isHapticFeedbackEnabled: false)
                    .onChange(of: crown) { _, value in model.crownChanged(value) }
                Text(model.message).font(.caption2)
                Button("Actualizar estado") { model.refresh() }
            }.padding(.horizontal)
        }.task { model.refresh() }
    }
}
```

Sustituir `GimbalPhoneApp.swift` por:
```swift
import SwiftUI
import GimbalHostSupport
import GimbalKitIntents

@main @MainActor struct GimbalPhoneApp: App {
    init() { PhoneWatchBridge.shared.activate() }
    var body: some Scene {
        WindowGroup {
            PhoneHomeView(model: PhoneHostComposition.model)
                .task { await PhoneHostComposition.model.start() }
        }
    }
}
```

El reloj nunca crea el runtime BLE. El callback de llegada se manda solo si el look acaba correctamente y su generación sigue activa. El número de secuencia del Watch se guarda en `UserDefaults` para no reiniciar a un valor antiguo si la app del reloj se relanza.

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: evento de llegada pasa con actors falsos; la suite no activa WCSession ni hápticos.

- [ ] **Step 5: Commit** (Claude): `feat: añadir UI Watch y puente WatchConnectivity`

---

### Task 7: XcodeGen, permisos y build de simuladores

**Files:**
- Create: `Apps/project.yml`
- Modify: `Package.swift`, `Apps/GimbalPhone/GimbalPhoneApp.swift`
- Test: suite Swift y builds xcodebuild iOS/watchOS Simulator

**Interfaces:**
- Consumes: productos SwiftPM locales y `/opt/homebrew/bin/xcodegen`.
- Produces: targets `GimbalPhone` iOS 17 y `GimbalWatch` watchOS 10; Watch embebido; descripción Bluetooth y modo `bluetooth-central`.

- [ ] **Step 1: Escribir la configuración base**

`Apps/project.yml`:
```yaml
name: GimbalKitApps
options:
  bundleIdPrefix: dev.gimbalkit
  deploymentTarget:
    iOS: "17.0"
    watchOS: "10.0"
  createIntermediateGroups: true
packages:
  GimbalKit:
    path: ..
targets:
  GimbalPhone:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources: [GimbalPhone]
    dependencies:
      - package: GimbalKit
        product: GimbalKit
      - package: GimbalKit
        product: GimbalKitBLE
      - package: GimbalKit
        product: GimbalHostSupport
      - package: GimbalKit
        product: GimbalKitIntents
      - package: GimbalKit
        product: GimbalWatchKit
      - target: GimbalWatch
        embed: true
    info:
      properties:
        NSBluetoothAlwaysUsageDescription: "Conectar y controlar el estabilizador desde GimbalKit."
        UIBackgroundModes: [bluetooth-central]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.gimbalkit.phone
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        CODE_SIGNING_ALLOWED: NO
        CODE_SIGNING_REQUIRED: NO
```

- [ ] **Step 2: Generar y comprobar el target inicial**

Run desde raíz (el target aún no está declarado):
```sh
cd Apps
/opt/homebrew/bin/xcodegen generate --spec project.yml
```
Expected: XcodeGen rechaza la referencia a `GimbalWatch` porque el target aún no existe. No ejecutar xcodebuild en este paso.

- [ ] **Step 3: Implementar**

Sustituir `Apps/project.yml` por:
```yaml
name: GimbalKitApps
options:
  bundleIdPrefix: dev.gimbalkit
  deploymentTarget:
    iOS: "17.0"
    watchOS: "10.0"
  createIntermediateGroups: true
packages:
  GimbalKit:
    path: ..
targets:
  GimbalPhone:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources: [GimbalPhone]
    dependencies:
      - package: GimbalKit
        product: GimbalKit
      - package: GimbalKit
        product: GimbalKitBLE
      - package: GimbalKit
        product: GimbalHostSupport
      - package: GimbalKit
        product: GimbalKitIntents
      - package: GimbalKit
        product: GimbalWatchKit
      - target: GimbalWatch
        embed: true
    info:
      properties:
        NSBluetoothAlwaysUsageDescription: "Conectar y controlar el estabilizador desde GimbalKit."
        UIBackgroundModes: [bluetooth-central]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.gimbalkit.phone
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        CODE_SIGNING_ALLOWED: NO
        CODE_SIGNING_REQUIRED: NO
  GimbalWatch:
    type: application
    platform: watchOS
    deploymentTarget: "10.0"
    sources: [GimbalWatch]
    dependencies:
      - package: GimbalKit
        product: GimbalWatchKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.gimbalkit.watch
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        CODE_SIGNING_ALLOWED: NO
        CODE_SIGNING_REQUIRED: NO
schemes:
  GimbalPhone:
    build:
      targets:
        GimbalPhone: all
    run:
      config: Debug
  GimbalWatch:
    build:
      targets:
        GimbalWatch: all
    run:
      config: Debug
```

Sustituir `Package.swift` por esta versión completa:
```swift
// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "GimbalKit", targets: ["GimbalKit"]),
    .library(name: "GimbalKitSim", targets: ["GimbalKitSim"]),
    .library(name: "GimbalKitDJI", targets: ["GimbalKitDJI"]),
    .library(name: "GimbalKitBLE", targets: ["GimbalKitBLE"]),
    .library(name: "GimbalLabSupport", targets: ["GimbalLabSupport"]),
]
var targets: [Target] = [
    .target(name: "GimbalKit"),
    .target(name: "GimbalKitSim", dependencies: ["GimbalKit"]),
    .target(name: "GimbalKitDJI", dependencies: ["GimbalKit"]),
    .target(name: "GimbalKitBLE", dependencies: ["GimbalKitDJI"]),
    .target(name: "GimbalLabSupport", dependencies: ["GimbalKit", "GimbalKitDJI"]),
    .testTarget(name: "GimbalKitTests", dependencies: ["GimbalKit", "GimbalKitSim"]),
    .testTarget(name: "GimbalKitDJITests", dependencies: ["GimbalKitDJI", "GimbalKit", "GimbalKitSim", "GimbalLabSupport"]),
]
#if os(macOS)
products += [
    .library(name: "GimbalKitMCP", targets: ["GimbalKitMCP"]),
    .library(name: "GimbalHostSupport", targets: ["GimbalHostSupport"]),
    .library(name: "GimbalKitIntents", targets: ["GimbalKitIntents"]),
    .library(name: "GimbalWatchKit", targets: ["GimbalWatchKit"]),
    .executable(name: "gimbal", targets: ["GimbalCLI"]),
    .executable(name: "GimbalHostMac", targets: ["GimbalHostMac"]),
    .executable(name: "GimbalLabMac", targets: ["GimbalLabMac"]),
]
targets += [
    .target(name: "GimbalKitMCP", dependencies: ["GimbalKit"]),
    .target(name: "GimbalHostSupport", dependencies: [
        "GimbalKit", "GimbalKitDJI", "GimbalKitBLE",
        .target(name: "GimbalKitMCP", condition: .when(platforms: [.macOS]))
    ]),
    .target(name: "GimbalKitIntents", dependencies: ["GimbalKit", "GimbalHostSupport"]),
    .target(name: "GimbalWatchKit", dependencies: [
        "GimbalKit",
        .target(name: "GimbalHostSupport", condition: .when(platforms: [.iOS, .macOS]))
    ]),
    .executableTarget(name: "GimbalCLI", dependencies: ["GimbalKitMCP"]),
    .executableTarget(name: "GimbalHostMac", dependencies: ["GimbalHostSupport", "GimbalKit", "GimbalKitBLE", "GimbalKitDJI", "GimbalKitMCP"]),
    .executableTarget(name: "GimbalLabMac", dependencies: ["GimbalLabSupport", "GimbalHostSupport", "GimbalKit", "GimbalKitBLE", "GimbalKitDJI"]),
    .executableTarget(name: "GimbalSmoke", dependencies: ["GimbalKitBLE", "GimbalKitDJI", "GimbalKit"]),
    .testTarget(name: "GimbalKitMCPTests", dependencies: ["GimbalKitMCP", "GimbalKit"]),
    .testTarget(name: "GimbalHostSupportTests", dependencies: ["GimbalHostSupport", "GimbalKit", "GimbalKitDJI", "GimbalKitMCP", "GimbalKitSim"]),
    .testTarget(name: "GimbalKitIntentsTests", dependencies: ["GimbalKitIntents", "GimbalHostSupport", "GimbalKit"]),
    .testTarget(name: "GimbalWatchKitTests", dependencies: ["GimbalWatchKit", "GimbalHostSupport", "GimbalKit", "GimbalKitSim"]),
]
#endif
let package = Package(
    name: "GimbalKit",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: products,
    targets: targets
)
```

La condición `GimbalKitMCP` excluye `Network.framework` de iOS; `GimbalWatchKit -> GimbalHostSupport` se excluye de watchOS, que compila solo mensajes. El manifiesto se ejecuta en Mac para que XcodeGen vea los productos locales multiplataforma.

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Ejecutar de uno en uno:
```sh
CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build
cd Apps
/opt/homebrew/bin/xcodegen generate --spec project.yml
cd ..
xcodebuild -project Apps/GimbalKitApps.xcodeproj -scheme GimbalPhone \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Apps/GimbalKitApps.xcodeproj -scheme GimbalWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
Expected: suite y ambas builds pasan. Si sandbox impide cargar SDK, guardar el error completo para Claude; no lanzar simuladores ni cambiar a build firmada.

- [ ] **Step 5: Commit** (Claude): `build: configurar apps iOS y Watch con XcodeGen`

---

### Task 8 (MANUAL, la hacen Claude y Jesús con iPhone, Watch y Osmo)

**Files:**
- Create: `docs/research/informe-ios-atajos-watch-2026-10-11.md` (actualizar fecha de ejecución)
- Modify después de medir: `docs/research/telemetria-om-se.md`, `docs/superpowers/plans/ESTADO.md`

**Interfaces:**
- Consumes: builds de teléfono/reloj, Atajos/Siri, WatchConnectivity, zonas/referencias y Osmo.
- Produces: informe de permisos, experiencia Siri/Watch, reconexión en segundo plano, stop/jog/look y estado M5. No firmar/distribuir.

- [ ] Instalar GimbalPhone en iPhone con firma local gestionada por Jesús; aceptar permiso Bluetooth. Ver conexión, reconexión, batería, pose, lista de zonas, referencia, registro y PARADA. Confirmar que no escucha puerto MCP.
- [ ] Guardar una zona, cancelar y comprobar que no persiste; guardar y confirmar; reconectar y comprobar que navegación queda bloqueada hasta confirmar nueva referencia.
- [ ] Añadir las cinco acciones a Atajos. Ver entidades por nombre y frases Siri en español. Probar look, stop, status, movimientos ±15° y rechazo 15,1°, cancelar confirmación de Guardar zona.
- [ ] Con app en segundo plano, despertar con intent y medir conexión ≤10 s. Repetir Osmo apagada: error claro y `openAppWhenRun`; encenderla y verificar reintento. Registrar TCC y duración, sin ampliar timeout para ocultar un fallo.
- [ ] Instalar/emparejar GimbalWatch. Ver estado, batería, pose redondeada y zonas; confirmar que no pide permiso Bluetooth ni habla con Osmo.
- [ ] Desde el Watch, mirar a zona y comprobar háptica al llegar; girar corona y soltar, verificar jog y STOP; pulsar PARADA durante jog/look y comprobar que SPEED no reaparece.
- [ ] Alejar el Watch o cortar WatchConnectivity durante movimiento: stop inmediato al perder reachability; si deja de llegar jog sin callback, deadman ≤0,6 s. Comprobar cadence física ≥0,25 s y límites reales.
- [ ] Documentar resultados medidos en el informe y actualizar `ESTADO.md`/telemetría solo con datos observados. No editar JSON de zonas ni mover límites para conseguir PASS. Claude hace commit documental.

---

## Autorrevisión

- **Cobertura:** host iOS sin MCP, DTO compartido y runtime único → Task 1; acciones testeables, timeout, fuente `.shortcut` y movimiento ≤15° → Task 2; ZoneEntity, cinco intents, español, confirmación y UI → Task 3; protocolo Codable → Task 4; secuencia/frescura/límites/cadencia/deadman/reachability/STOP prioritario → Task 5; Watch UI y mensajes → Task 6; XcodeGen, permisos y builds → Task 7; validación física/background → Task 8.
- **Código completo:** tests, DTOs, servicios, vistas y proyecto aparecen con código concreto. No hay marcadores ni referencias «igual que Task N». Los métodos que se insertan en código existente quedan nombrados y con contrato exacto.
- **Consistencia:** DTOs pasan a `GimbalKit`; `HostMCPService` conserva la interfaz MCP en macOS; `HostRuntime` no importa MCP; intents, app y Watch usan `PhoneHostComposition.runtime`; `HostShortcutRuntime` está en el target de intents y `HostWatchRuntime` en el target WatchKit para evitar ciclos; el Watch no enlaza BLE.
- **Seguridad:** intent desconectado falla al cabo de 10 s; mover relativo verifica destino/lease/zona y usa navegador con pulsos; Watch STOP prioriza, cancela y evita velocidades antiguas; SafetyPolicy sigue limitando `.app`.
- **Riesgo y límites:** `swift test` no demuestra BLE en segundo plano, TCC, Siri, alcance ni hápticos; Task 8 lo prueba. Firma/perfil/distribución quedan para Jesús. Si xcodebuild es bloqueado por sandbox, no declarar la build aprobada.
- **Decisiones de uso:** jog son °/s, máximo de protocolo 12 °/s y política actual 6 °/s; cadence mínima 0,25 s; timestamp ≤0,6 s; deadman 0,6 s; corona envía STOP tras 0,3 s sin eventos; look usa lease `.app`.
- **Entrega:** Tasks 1–7 automáticas con pruebas/builds y commits de Claude; Task 8 manual con informe. Durante este encargo solo se crea este plan.
