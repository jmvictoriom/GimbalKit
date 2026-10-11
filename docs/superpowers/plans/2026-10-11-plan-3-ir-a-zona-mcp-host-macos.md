# GimbalKit — Plan 3: ir a zona, MCP HTTP y anfitrión macOS

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Controlar el centro de una zona con pose retardada, servir las cuatro herramientas MCP en HTTP local autenticado y entregar una app macOS de barra de menús, dueña única del Bluetooth, con persistencia, auditoría y la CLI `gimbal`.

**Architecture:** `GotoNavigator` vive en `GimbalKit` y solo mueve mediante `GimbalController`. Usa pulsos proporcionales, parada y asentamiento entre pulsos: no presupone posición absoluta ni realimenta continuamente una pose vieja. `GimbalKitMCP` separa `GimbalService`, JSON-RPC, parser HTTP y `NWListener`. `GimbalHostSupport` contiene un runtime actor y un modelo `@MainActor` probado con transportes falsos; `GimbalHostMac` compone CoreBluetooth y SwiftUI. La CLI es un cliente HTTP y nunca importa Bluetooth. Cada conexión nueva tiene un dispositivo y una referencia nuevos; las zonas persistidas quedan visibles pero inhabilitadas hasta confirmación humana de esa referencia.

**Tech Stack:** Swift tools/lenguaje 6, concurrencia estricta, Swift Testing, Foundation, Security, Network.framework, SwiftUI `MenuBarExtra`; macOS 14+. Cero dependencias de terceros.

**Spec:** `docs/superpowers/specs/2026-10-11-gimbalkit-v1-design.md` (§4, §7, §8; M4), los Planes 1 y 2, `docs/research/telemetria-om-se.md` y `docs/superpowers/plans/ESTADO.md`. Este plan sustituye las menciones antiguas a iOS y HID como alcance del Plan 3: iOS/Atajos es Plan 4; HID queda pendiente, sin capacidades inventadas.

## Global Constraints

- Este documento es un encargo de implementación futuro. El redactor solo crea este fichero; no implementa, compila, conecta, usa la red ni hace commits.
- El implementador tampoco puede hacer commits en este sandbox. Cada Step «Commit» es una entrega a Claude, quien hará el commit indicado; no ejecutar `git add` ni `git commit`.
- Ejecutar una sola suite/compilación a la vez, desde la raíz: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`. Los comandos completos de cada tarea conservan estas opciones. No ocultar fallos con `tail` ni tuberías sin `pipefail`.
- Pruebas nuevas con Swift Testing, directorios temporales exclusivos, reloj inyectado, continuaciones o señales. Ninguna abre CoreBluetooth; las de HTTP usan exclusivamente loopback, puerto 0 y `URLSession` efímera con timeout. No hay esperas reales para navegador, reconexión ni timeout de lectura.
- El servidor solo escucha IPv4 `127.0.0.1`; no `0.0.0.0`, no IPv6 comodín. No acepta credenciales, fuentes de control, límites ni política en parámetros MCP. Todas las llamadas remotas usan `.agent("mcp")`; PARADA humana usa `.app`.
- `gimbal_look` exige `0 < lease_seconds <= 30` (por defecto 30), retiene el lease tras llegar y lo deja caducar con `tick()`. Error/cancelación liberan exclusivamente el lease de esa operación. Al apagar MCP, parar y revocar el lease MCP, aunque la Osmo siga conectada.
- La pose tiene **marca de recepción y secuencia**, renovadas por cada trama válida aunque los ángulos sean idénticos. Leer la caché no renueva ninguna marca. El reloj de producción se basa en `ContinuousClock` y se proyecta a `Date` para conservar la API existente.
- Límites iniciales del navegador: máximo 6 °/s (menor que 12), ganancia 1 s⁻¹, banda muerta 2°, pulsos de 0,30 s, frenado supuesto 0,20 s, ganancia física conservadora 1,25, margen angular 0,5°, retardo supuesto máximo 0,70 s, asentamiento mínimo 0,90 s y dos marcas nuevas después de cada parada. Pose sin marca nueva durante >1,5 s → parada y `NavigationError.stalePose`; timeout total 25 s.
- Se rechaza empezar fuera de la zona del lease, cruzar una zona prohibida o no disponer de margen para el pulso. Las zonas disjuntas no son destinos accesibles desde fuera: recolocación humana o zonas permitidas solapadas. No añadir trayectorias fuera del lease ni modos absolutos.
- La envolvente de cada pulso incluye todo el segmento, el margen y la distancia durante frenado; se comprueba también en el controlador. La garantía física depende de las cotas anteriores y de que nadie mueva la base/dispositivo por fuera del software. No declarar garantía física universal: la Task 11 valida las cotas en la SE antes de habilitar uso habitual.
- Guardar zonas requiere confirmación en pantalla y pose fresca. Las referencias del Plan 2 son relativas a la primera orientación: reconectar o relanzar invalida la habilitación de zonas; solo la persona puede confirmarla. No convertir automáticamente una referencia nueva en la antigua.
- Todo bloque es código completo del fichero o del miembro indicado. Las inserciones en ficheros existentes especifican su ubicación. No copiar código de otros planes ni usar marcadores para completar este plan.

## Review Focus

- Frescura confundida con cambio angular; telemetría congelada, pose inexistente, timeout, NaN y cancelación en una lectura suspendida.
- Actor reentrante: parada durante lookup/envío, colas con velocidades antiguas, cleanup de una operación revocando un lease nuevo, respuesta de conexión/servidor antigua sobrescribiendo el estado actual.
- Frenado sobre datos retardados, huecos entre zonas, contacto con un rectángulo prohibido, cadencia de SPEED entre operaciones y deadman durante pulsos.
- Parser HTTP: límites antes de reservar memoria, cabecera fragmentada, `Content-Length` duplicado/negativo/desbordado, `Transfer-Encoding`, obs-fold, pipelining, cierre temprano, slowloris y conexiones concurrentes sin límite.
- Bind y DNS rebinding: Host y Origin exactos con puerto real; no aceptar sufijos de `localhost`, direcciones numéricas alternativas ni Origin `null`; ausencia de Origin permite clientes nativos autenticados.
- Token de 32 bytes aleatorios, archivo regular del usuario, 0600 desde la creación, sin enlaces simbólicos; comparación de longitud fija sin salida temprana por byte; nunca token en logs/errores. La copia al portapapeles es una acción humana explícita.
- JSON-RPC: notificaciones sin efectos de movimiento, IDs válidos, cinco errores estándar, nombres/argumentos cerrados, errores de herramienta con `isError`, ningún texto que edite política.
- Reconexión: backoff cancelable y acotado, un solo intento, transporte nuevo por intento, referencia invalidada, limpieza de suscripciones, tareas y listener al salir.

---

## File Structure

```text
Package.swift
Sources/GimbalKit/
  PoseFeedback.swift          PoseSample, PoseFeedbackDevice, RuntimeClock
  NavigationSafety.swift      NavigationLimits, NavigationError, NavigationContext, envolvente
  GimbalController.swift      cola de órdenes, épocas, API del navegador y cambio humano de zonas
  GotoNavigator.swift         bucle proporcional por pulsos, cancelación y timeout
  ZoneStore.swift             JSON validado y recuperación .bak
Sources/GimbalKitDJI/OMDevice.swift        marcas de telemetría y ingest determinista interno
Sources/GimbalKitSim/LaggedPoseDevice.swift
Sources/GimbalKitMCP/
  LocalFiles.swift            token privado y descubrimiento del puerto
  GimbalService.swift         DTO y protocolo sin red
  JSONValue.swift             JSON Sendable/Codable
  MCPDispatcher.swift         JSON-RPC y esquemas cerrados de herramientas
  HTTPParser.swift            parser incremental y gate Host/Origin/Bearer
  HTTPServer.swift            listener y peers, límites y cancelación
  MCPClient.swift             URLSession y negociación para CLI
Sources/GimbalHostSupport/
  HostRuntime.swift           conexión, reconexión, tick, servicio y zonas humanas
  HostModel.swift             Observation, servidor y estado de presentación
  HostInstanceLock.swift      exclusión de un segundo anfitrión antes de Bluetooth
Sources/GimbalHostMac/GimbalHostApp.swift  vistas, adapter BLE y lifecycle AppKit
Sources/GimbalCLI/GimbalCLI.swift
Sources/GimbalKitBLE/CoreBluetoothOMTransport.swift  cancelación de conexión y callback sincronizado
scripts/build-host-mac.sh
Tests/GimbalKitTests/          NavigationControllerTests, GotoNavigatorTests, ZoneStoreTests
Tests/GimbalKitDJITests/PoseSampleTests.swift
Tests/GimbalKitMCPTests/       LocalFilesTests, DispatcherTests, HTTPParserTests, HTTPServerTests, ClientTests
Tests/GimbalHostSupportTests/  HostRuntimeTests, HostModelTests
scripts/check-host-bundle.sh
```

---

### Task 1: Pose con marca real y reloj compartido

**Files:**
- Create: `Sources/GimbalKit/PoseFeedback.swift`
- Modify: `Sources/GimbalKitDJI/OMDevice.swift` (sustituir fichero)
- Test: `Tests/GimbalKitDJITests/PoseSampleTests.swift`

**Interfaces:**
- Consumes: `GimbalDevice.currentPose() async -> Pose?`, `OMTransport.write(_:) async throws`, `OMTransport.notifications: AsyncStream<[UInt8]>`, `OMPoseEstimator.update(_:) -> Pose`, `FakeTransport`, `Real.yawA` y `realBytes(_:)` actuales.
- Produces: `PoseSample.init(pose: Pose, receivedAt: Date, sequence: UInt64)`; `protocol PoseFeedbackDevice: GimbalDevice { func poseSample() async -> PoseSample? }`; `RuntimeClock.init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Double) async throws -> Void)`, `static var live: RuntimeClock`, `now: @Sendable () -> Date`, `sleep: @Sendable (Double) async throws -> Void`; `OMDevice.init(transport: any OMTransport, now: @escaping @Sendable () -> Date = { Date() })`, `poseSample() -> PoseSample?`, `ingest(_ chunk: [UInt8])` interno para pruebas.

- [ ] **Step 1: Escribir la prueba que falla**

`Tests/GimbalKitDJITests/PoseSampleTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit
@testable import GimbalKitDJI

@Test func identicalAttitudesHaveNewMarksButCacheReadsDoNot() async throws {
    let device = OMDevice(transport: FakeTransport(), now: { Date(timeIntervalSince1970: 10) })
    #expect(await device.poseSample() == nil)
    await device.ingest(realBytes(Real.yawA))
    let a = try #require(await device.poseSample())
    #expect(await device.poseSample() == a)
    await device.ingest(realBytes(Real.yawA))
    let b = try #require(await device.poseSample())
    #expect(a.pose == b.pose)
    #expect(b.sequence == a.sequence + 1)
    #expect(b.receivedAt == Date(timeIntervalSince1970: 10))
    await device.ingest(realBytes(Real.battery))
    #expect(await device.poseSample() == b)
    await device.zeroPose()
    #expect(await device.poseSample() == nil)
    await device.ingest(realBytes(Real.yawA))
    await device.shutdown()
    #expect(await device.currentPose() == nil)
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter identicalAttitudesHaveNewMarksButCacheReadsDoNot`
Expected: no existe `poseSample`/el parámetro `now`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKit/PoseFeedback.swift`:
```swift
import Foundation

public struct PoseSample: Sendable, Equatable {
    public let pose: Pose
    public let receivedAt: Date
    public let sequence: UInt64
    public init(pose: Pose, receivedAt: Date, sequence: UInt64) {
        self.pose = pose; self.receivedAt = receivedAt; self.sequence = sequence
    }
}

public protocol PoseFeedbackDevice: GimbalDevice {
    func poseSample() async -> PoseSample?
}

public struct RuntimeClock: Sendable {
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (Double) async throws -> Void
    public init(now: @escaping @Sendable () -> Date,
                sleep: @escaping @Sendable (Double) async throws -> Void) {
        self.now = now; self.sleep = sleep
    }
    public static var live: RuntimeClock {
        let base = Date()
        let start = ContinuousClock.now
        return RuntimeClock(now: {
            let c = start.duration(to: ContinuousClock.now).components
            return base.addingTimeInterval(Double(c.seconds) + Double(c.attoseconds) / 1e18)
        }, sleep: { try await Task.sleep(for: .seconds($0)) })
    }
}
```

`Sources/GimbalKitDJI/OMDevice.swift`:
```swift
import Foundation
import GimbalKit

public protocol OMTransport: Sendable {
    func write(_ bytes: [UInt8]) async throws
    var notifications: AsyncStream<[UInt8]> { get }
}
public enum OMDeviceError: Error, Equatable { case unsupported(String) }

/// SPEED cada >=0,25 s; nunca simula control absoluto. Un dispositivo por conexión.
public actor OMDevice: PoseFeedbackDevice {
    public nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback, .battery]
    public private(set) var battery: (percent: Int, charging: Bool)?
    private let transport: any OMTransport
    private let now: @Sendable () -> Date
    private var parser = DUMLParser()
    private var estimator = OMPoseEstimator()
    private var sample: PoseSample?
    private var sequence: UInt64 = 0
    private var listener: Task<Void, Never>?

    public init(transport: any OMTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.now = now
    }
    public func start() {
        guard listener == nil else { return }
        let stream = transport.notifications
        listener = Task { [weak self] in
            for await chunk in stream {
                guard !Task.isCancelled else { break }
                await self?.ingest(chunk)
            }
        }
    }
    public func shutdown() {
        listener?.cancel(); listener = nil
        estimator.zero(); sample = nil; battery = nil; parser = DUMLParser()
    }
    public func zeroPose() { estimator.zero(); sample = nil }
    public func currentPose() -> Pose? { sample?.pose }
    public func poseSample() -> PoseSample? { sample }
    public func send(_ command: MoveCommand) async throws {
        switch command {
        case let .speed(yaw, pitch, _):
            try await write(yaw: OMUnits.raw(forDegreesPerSecond: yaw), pitch: OMUnits.raw(forDegreesPerSecond: pitch))
        case .stop: try await write(yaw: 0, pitch: 0)
        case .absolute: throw OMDeviceError.unsupported("absolute")
        }
    }
    private func write(yaw: Int16, pitch: Int16) async throws {
        try await transport.write(OMRotate(yaw: yaw, pitch: pitch, roll: 0, time: 10, mode: .speed).frame().encoded())
    }
    func ingest(_ chunk: [UInt8]) {
        for frame in parser.feed(chunk) {
            switch OMTelemetry.decode(frame) {
            case let .attitude(q)?:
                sequence &+= 1
                sample = PoseSample(pose: estimator.update(q), receivedAt: now(), sequence: sequence)
            case let .battery(percent, charging)?: battery = (percent, charging)
            case nil: break
            }
        }
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: prueba nueva y las 59 pruebas anteriores pasan. No ejecutar el smoke.

- [ ] **Step 5: Commit** (Claude): `feat: marcas de telemetría y reloj monotónico inyectable`

---

### Task 2: Controlador con cola ordenada y envolvente de navegación

**Files:**
- Create: `Sources/GimbalKit/NavigationSafety.swift`
- Modify: `Sources/GimbalKit/GimbalController.swift` (sustituir fichero)
- Test: `Tests/GimbalKitTests/NavigationControllerTests.swift`

**Interfaces:**
- Consumes: API actual `requestLease(source:zone:seconds:) async throws -> Lease`, `send(_:source:lease:) async throws`, `stop(source:) async`, `tick() async`, `deviceDisconnected() async`, `AuditLog.entries() -> [AuditEntry]`; Task 1 `PoseFeedbackDevice`.
- Produces: conserva esas firmas; `zones: [Zone]`, `replaceZones(_ zones: [Zone]) async`, `navigationContext(source: ControlSource, lease: Lease) async throws -> NavigationContext`, `navigationPulse(_ velocity: Pose, source: ControlSource, lease: Lease) async throws`, `haltNavigation(lease: Lease) async throws`, `release(lease: Lease) async`; `NavigationSafety.check(pose: Pose, velocity: Pose, zone: Zone, forbidden: [Zone], limits: NavigationLimits) throws`.

- [ ] **Step 1: Escribir las pruebas que fallan**

`Tests/GimbalKitTests/NavigationControllerTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit
import GimbalKitSim

actor OrderedDevice: PoseFeedbackDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    private(set) var commands: [MoveCommand] = []
    private var pending: CheckedContinuation<Void, Never>?
    var waiting: Bool { pending != nil }
    func currentPose() -> Pose? { Pose() }
    func poseSample() -> PoseSample? { PoseSample(pose: Pose(), receivedAt: Date(timeIntervalSince1970: 1_000_000), sequence: 1) }
    func send(_ command: MoveCommand) async throws {
        if case .speed = command { await withCheckedContinuation { pending = $0 } }
        commands.append(command)
    }
    func open() { pending?.resume(); pending = nil }
}

@Test func queuedSpeedCannotFollowConcurrentStop() async throws {
    let dev = OrderedDevice()
    let clock = ManualClock()
    let c = GimbalController(device: dev, policy: makePolicy(), now: { clock.now() })
    let l = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 20)
    let moving = Task { try await c.navigationPulse(Pose(yaw: 2), source: l.source, lease: l) }
    while !(await dev.waiting) { await Task.yield() }
    let stopping = Task { await c.stop(source: .app) }
    while await c.activeLease != nil { await Task.yield() }
    await dev.open()
    _ = try? await moving.value
    await stopping.value
    #expect(await dev.commands == [.speed(yaw: 2, pitch: 0, roll: 0), .stop])
    let newer = try await c.requestLease(source: .agent("nuevo"), zone: "mesa", seconds: 5)
    await c.release(lease: l)
    #expect(await c.activeLease?.id == newer.id)
}

@Test func envelopeRejectsBoundaryAndForbiddenCrossing() throws {
    let z = Zone(name: "ancha", yaw: -20...20, pitch: -20...20)
    let forbidden = Zone(name: "privada", yaw: 0.7...1, pitch: -1...1, forbidden: true)
    #expect(throws: NavigationError.unsafePath) {
        try NavigationSafety.check(pose: Pose(), velocity: Pose(yaw: 6), zone: z,
                                   forbidden: [forbidden], limits: NavigationLimits())
    }
    #expect(throws: NavigationError.unsafePath) {
        try NavigationSafety.check(pose: Pose(yaw: 19), velocity: Pose(yaw: 6), zone: z,
                                   forbidden: [], limits: NavigationLimits())
    }
    try NavigationSafety.check(pose: Pose(), velocity: Pose(yaw: -2), zone: z,
                               forbidden: [forbidden], limits: NavigationLimits())
}

@Test func navigationAlsoRespectsControllerSpeedPolicy() async throws {
    let dev = OrderedDevice()
    let clock = ManualClock()
    var policy = makePolicy()
    policy.maxSpeed = 1
    let c = GimbalController(device: dev, policy: policy, now: { clock.now() })
    let lease = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 5)
    await #expect(throws: SafetyViolation.speedTooHigh(limit: 1, requested: 2)) {
        try await c.navigationPulse(Pose(yaw: 2), source: lease.source, lease: lease)
    }
    #expect(await dev.commands.isEmpty)
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter 'queuedSpeedCannotFollowConcurrentStop|envelopeRejectsBoundaryAndForbiddenCrossing'`
Expected: faltan `navigationPulse` y `NavigationSafety`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKit/NavigationSafety.swift`:
```swift
import Foundation

public struct NavigationLimits: Sendable {
    public let maxSpeed = 6.0
    public let gain = 1.0
    public let deadband = 2.0
    public let pulseSeconds = 0.30
    public let brakingSeconds = 0.20
    public let physicalGain = 1.25
    public let margin = 0.5
    public let settleSeconds = 0.90
    public let staleSeconds = 1.5
    public let timeoutSeconds = 25.0
    public init() {}
}
public enum NavigationError: Error, Sendable, Equatable {
    case stalePose, timeout, unsafePath, interrupted, busy, referenceRequired
}
public struct NavigationContext: Sendable {
    public let zone: Zone
    public let forbidden: [Zone]
    public let sample: PoseSample
}
public enum NavigationSafety {
    public static func check(pose p: Pose, velocity v: Pose, zone: Zone,
                             forbidden: [Zone], limits l: NavigationLimits) throws {
        guard p.isFinite, v.isFinite, v.roll == 0,
              max(abs(v.yaw), abs(v.pitch)) <= l.maxSpeed else { throw SafetyViolation.invalidValue }
        let t = (l.pulseSeconds + l.brakingSeconds) * l.physicalGain
        let q = Pose(yaw: p.yaw + v.yaw * t, pitch: p.pitch + v.pitch * t)
        let y = (min(p.yaw, q.yaw) - l.margin)...(max(p.yaw, q.yaw) + l.margin)
        let x = (min(p.pitch, q.pitch) - l.margin)...(max(p.pitch, q.pitch) + l.margin)
        guard zone.yaw.lowerBound <= y.lowerBound, zone.yaw.upperBound >= y.upperBound,
              zone.pitch.lowerBound <= x.lowerBound, zone.pitch.upperBound >= x.upperBound,
              !forbidden.contains(where: { $0.yaw.overlaps(y) && $0.pitch.overlaps(x) }) else {
            throw NavigationError.unsafePath
        }
    }
}
```

`Sources/GimbalKit/GimbalController.swift`:
```swift
import Foundation

public actor GimbalController {
    private let device: any GimbalDevice
    private var policy: SafetyPolicy
    private let now: @Sendable () -> Date
    public let audit: AuditLog
    private var lease: Lease?
    private var movingBySpeed = false
    private var lastSpeedAt: Date?
    private var lastNavigationSpeedAt: Date?
    private var epoch: UInt64 = 0
    private struct Job {
        let command: MoveCommand
        let epoch: UInt64
        let completion: CheckedContinuation<Void, any Error>
    }
    private var jobs: [Job] = []
    private var pumping = false
    private let limits = NavigationLimits()

    public init(device: any GimbalDevice, policy: SafetyPolicy,
                now: @escaping @Sendable () -> Date = { Date() }, audit: AuditLog = AuditLog()) {
        self.device = device; self.policy = policy; self.now = now; self.audit = audit
    }
    public var activeLease: Lease? {
        guard let lease, lease.expiresAt > now() else { return nil }
        return lease
    }
    public var zones: [Zone] { policy.zones }
    public func replaceZones(_ zones: [Zone]) async {
        invalidate()
        policy.zones = zones
        try? await enqueue(.stop)
        await record(.app, "zones replaced", .accepted)
    }
    public func requestLease(source: ControlSource, zone name: String, seconds: Double) async throws -> Lease {
        do {
            guard seconds.isFinite, seconds > 0 else { throw SafetyViolation.invalidDuration }
            guard seconds <= policy.maxLeaseSeconds else { throw SafetyViolation.leaseTooLong(max: policy.maxLeaseSeconds) }
            guard let zone = policy.zone(named: name) else { throw SafetyViolation.unknownZone(name) }
            guard !zone.forbidden else { throw SafetyViolation.forbiddenZone(name) }
            if let active = activeLease, active.source != source {
                guard source.isPrivileged else { throw SafetyViolation.busy(holder: active.source) }
                invalidate()
                // Reservar antes del await evita que otro solicitante se cuele durante la parada.
                lease = Lease(source: source, zone: name, expiresAt: now().addingTimeInterval(seconds))
                let reserved = lease!
                try await enqueue(.stop)
                guard lease?.id == reserved.id else { throw NavigationError.interrupted }
                await record(source, "lease \(name) \(seconds)s", .accepted)
                return reserved
            }
            let granted = Lease(source: source, zone: name, expiresAt: now().addingTimeInterval(seconds))
            lease = granted
            await record(source, "lease \(name) \(seconds)s", .accepted)
            return granted
        } catch {
            await record(source, "lease \(name)", .rejected(Self.describe(error)))
            throw error
        }
    }
    public func send(_ command: MoveCommand, source: ControlSource, lease presented: Lease? = nil) async throws {
        do {
            let before = epoch
            var pose: Pose?
            if case .speed = command, device.capabilities.contains(.poseFeedback) { pose = await device.currentPose() }
            try validate(command, source: source, presented: presented, pose: pose)
            guard before == epoch else { throw NavigationError.interrupted }
            try Task.checkCancellation()
            let sentEpoch = epoch
            try await enqueue(command)
            if sentEpoch == epoch {
                switch command {
                case let .speed(y, p, r): movingBySpeed = y != 0 || p != 0 || r != 0; lastSpeedAt = now()
                case .absolute, .stop: movingBySpeed = false
                }
            }
            await record(source, "\(command)", .accepted)
        } catch {
            await record(source, "\(command)", .rejected(Self.describe(error)))
            throw error
        }
    }
    private func validate(_ command: MoveCommand, source: ControlSource, presented: Lease?, pose: Pose?) throws {
        if case .stop = command { return }
        switch command {
        case let .speed(y, p, r):
            guard device.capabilities.contains(.speedControl) else { throw SafetyViolation.unsupported(.speedControl) }
            guard y.isFinite, p.isFinite, r.isFinite else { throw SafetyViolation.invalidValue }
            let peak = max(abs(y), abs(p), abs(r))
            guard peak <= policy.maxSpeed else { throw SafetyViolation.speedTooHigh(limit: policy.maxSpeed, requested: peak) }
        case let .absolute(p, seconds):
            guard device.capabilities.contains(.absoluteControl) else { throw SafetyViolation.unsupported(.absoluteControl) }
            guard p.isFinite, seconds.isFinite, seconds >= 0 else { throw SafetyViolation.invalidValue }
        case .stop: return
        }
        if source.isPrivileged { return }
        guard let active = activeLease else { throw presented == nil ? SafetyViolation.noLease : SafetyViolation.leaseExpired }
        guard presented?.id == active.id, source == active.source else { throw SafetyViolation.noLease }
        guard let zone = policy.zone(named: active.zone) else { throw SafetyViolation.unknownZone(active.zone) }
        let checked: Pose
        switch command {
        case let .absolute(p, _): checked = p
        case .speed:
            guard device.capabilities.contains(.poseFeedback), let pose else { throw SafetyViolation.poseUnavailable }
            checked = pose
        case .stop: return
        }
        if let f = policy.forbiddenZone(containing: checked) { throw SafetyViolation.forbiddenZone(f.name) }
        guard zone.contains(checked) else { throw SafetyViolation.outsideZone(zone.name) }
    }
    public func navigationContext(source: ControlSource, lease presented: Lease) async throws -> NavigationContext {
        let before = epoch
        guard let feedback = device as? any PoseFeedbackDevice,
              let sample = await feedback.poseSample() else { throw SafetyViolation.poseUnavailable }
        try validate(.speed(yaw: 0, pitch: 0, roll: 0), source: source, presented: presented, pose: sample.pose)
        guard before == epoch, activeLease?.id == presented.id, presented.source == source else { throw NavigationError.interrupted }
        let age = now().timeIntervalSince(sample.receivedAt)
        guard age >= 0, age <= limits.staleSeconds else { throw NavigationError.stalePose }
        return NavigationContext(zone: policy.zone(named: presented.zone)!,
                                 forbidden: policy.zones.filter(\.forbidden), sample: sample)
    }
    public func navigationPulse(_ velocity: Pose, source: ControlSource, lease: Lease) async throws {
        let context = try await navigationContext(source: source, lease: lease)
        try Task.checkCancellation()
        let command = MoveCommand.speed(yaw: velocity.yaw, pitch: velocity.pitch, roll: velocity.roll)
        try validate(command, source: source, presented: lease, pose: context.sample.pose)
        try NavigationSafety.check(pose: context.sample.pose, velocity: velocity, zone: context.zone,
                                   forbidden: context.forbidden, limits: limits)
        if let last = lastNavigationSpeedAt, now().timeIntervalSince(last) < limits.pulseSeconds {
            throw NavigationError.unsafePath
        }
        guard activeLease?.id == lease.id else { throw NavigationError.interrupted }
        let e = epoch
        lastNavigationSpeedAt = now()
        movingBySpeed = true; lastSpeedAt = now()
        try await enqueue(command)
        guard e == epoch else { throw NavigationError.interrupted }
        await record(source, "navigation pulse \(lease.zone)", .accepted)
    }
    public func haltNavigation(lease presented: Lease) async throws {
        guard lease?.id == presented.id else { throw NavigationError.interrupted }
        movingBySpeed = false
        try await enqueue(.stop)
    }
    public func release(lease presented: Lease) async {
        guard lease?.id == presented.id else { return }
        invalidate()
        try? await enqueue(.stop)
        await record(presented.source, "lease released", .accepted)
    }
    public func stop(source: ControlSource) async {
        epoch &+= 1; movingBySpeed = false
        if source.isPrivileged || lease?.source == source { lease = nil }
        try? await enqueue(.stop)
        await record(source, "stop", .accepted)
    }
    public func tick() async {
        if let lease, lease.expiresAt <= now() { await revokeLease(reason: "expired"); return }
        guard movingBySpeed else { return }
        if let lastSpeedAt, now().timeIntervalSince(lastSpeedAt) > policy.deadmanSeconds {
            await revokeLease(reason: "deadman"); return
        }
        let before = epoch
        if let lease, !lease.source.isPrivileged, let zone = policy.zone(named: lease.zone),
           let pose = await device.currentPose(), before == epoch,
           !zone.contains(pose) || policy.forbiddenZone(containing: pose) != nil {
            await revokeLease(reason: "left zone")
        }
    }
    public func deviceDisconnected() async {
        invalidate()
        await record(nil, "device disconnected", .accepted)
    }
    private func invalidate() { epoch &+= 1; lease = nil; movingBySpeed = false }
    func revokeLease(reason: String) async {
        let source = lease?.source
        invalidate()
        try? await enqueue(.stop)
        await record(source, "lease revoked: \(reason)", .accepted)
    }
    private func enqueue(_ command: MoveCommand) async throws {
        try await withCheckedThrowingContinuation { continuation in
            jobs.append(Job(command: command, epoch: epoch, completion: continuation))
            if !pumping { pumping = true; Task { await self.pump() } }
        }
    }
    private func pump() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            if job.command != .stop, job.epoch != epoch {
                job.completion.resume(throwing: NavigationError.interrupted); continue
            }
            do { try await device.send(job.command); job.completion.resume() }
            catch { job.completion.resume(throwing: error) }
        }
        pumping = false
    }
    func record(_ source: ControlSource?, _ event: String, _ outcome: AuditEntry.Outcome) async {
        await audit.record(AuditEntry(date: now(), source: source, event: event, outcome: outcome))
    }
    static func describe(_ error: any Error) -> String {
        String(String(describing: error).prefix { $0 != "(" })
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: nuevas pruebas y suite anterior verdes, incluida `stopDuringPoseLookupCancelsTheInFlightSpeedCommand` (conserva `leaseExpired` porque la validación de lease precede al error de época). La cola no inicia un segundo envío hasta terminar el primero; una escritura ya iniciada se completa antes de la parada y nunca se reordena detrás de ella.

- [ ] **Step 5: Commit** (Claude): `feat: navegación acotada y serialización de órdenes y paradas`

---

### Task 3: GotoNavigator con telemetría retardada y cancelación

**Files:**
- Create: `Sources/GimbalKit/GotoNavigator.swift`, `Sources/GimbalKitSim/LaggedPoseDevice.swift`
- Test: `Tests/GimbalKitTests/GotoNavigatorTests.swift`

**Interfaces:**
- Consumes: Task 2 `navigationContext(source: ControlSource, lease: Lease) async throws -> NavigationContext`, `navigationPulse(_ velocity: Pose, source: ControlSource, lease: Lease) async throws`, `haltNavigation(lease: Lease) async throws`, `release(lease: Lease) async`; Task 1 `RuntimeClock`; actuales `SimGimbal.advance(seconds: Double)`, `ManualClock.now() -> Date`, `advance(_ seconds: TimeInterval)` y el fixture `GatedPoseDevice.currentPose() async -> Pose?` de `DeadmanTests.swift`.
- Produces: `public actor GotoNavigator { init(controller: GimbalController, clock: RuntimeClock = .live); func go(to zoneName: String, source: ControlSource, lease: Lease) async throws -> Pose }`; `LaggedPoseDevice.init(clock: ManualClock, pose: Pose = Pose())`, `advance(_ seconds: Double) async`, `setFrozen(_ value: Bool)`, `setImmobile(_ value: Bool)`, `private(set) var frozen: Bool`, `truePoses: [Pose]`, `sent: [(Date, MoveCommand)]`. El wrapper simula además ganancia 1,25 y 0,20 s de frenado con la velocidad anterior, las cotas usadas por la envolvente.

- [ ] **Step 1: Escribir las pruebas que fallan**

`Tests/GimbalKitTests/GotoNavigatorTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit
import GimbalKitSim

func navigationFixture(frozen: Bool = false, timeout: Bool = false) async throws
    -> (GotoNavigator, GimbalController, LaggedPoseDevice, Lease) {
    let clock = ManualClock()
    let dev = LaggedPoseDevice(clock: clock, pose: Pose(yaw: -8, pitch: -6))
    await dev.setFrozen(frozen)
    await dev.setImmobile(timeout)
    let zone = Zone(name: "mesa", yaw: -12...12, pitch: -12...12)
    let c = GimbalController(device: dev, policy: makePolicy(zones: [zone]), now: { clock.now() })
    let timing = RuntimeClock(now: { clock.now() }, sleep: { seconds in
        try Task.checkCancellation()
        await dev.advance(seconds)
        await c.tick()
        await Task.yield()
    })
    let lease = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 30)
    return (GotoNavigator(controller: c, clock: timing), c, dev, lease)
}

@Test func gotoWithLagStaysInsideZoneAndUsesOnlySpacedSpeedAndStop() async throws {
    let (nav, c, dev, lease) = try await navigationFixture()
    let pose = try await nav.go(to: "mesa", source: lease.source, lease: lease)
    #expect(abs(pose.yaw) <= 2 && abs(pose.pitch) <= 2)
    #expect(await dev.truePoses.allSatisfy { (-12.0...12).contains($0.yaw) && (-12.0...12).contains($0.pitch) })
    let sent = await dev.sent
    let speeds = sent.compactMap { date, command -> Date? in
        if case let .speed(y, p, r) = command {
            #expect(max(abs(y), abs(p)) <= 6 && r == 0)
            return date
        }
        #expect(command == .stop)
        return nil
    }
    for i in speeds.indices.dropFirst() { #expect(speeds[i].timeIntervalSince(speeds[i - 1]) >= 0.25) }
    #expect(sent.last?.1 == .stop)
    #expect(await c.activeLease?.id == lease.id)
}

@Test func frozenPoseAndUnreachableTargetStopWithTypedErrors() async throws {
    for frozen in [true, false] {
        let (nav, c, dev, lease) = try await navigationFixture(frozen: frozen, timeout: !frozen)
        await #expect(throws: frozen ? NavigationError.stalePose : NavigationError.timeout) {
            try await nav.go(to: "mesa", source: lease.source, lease: lease)
        }
        #expect(await dev.sent.last?.1 == .stop)
        #expect(await c.activeLease == nil)
    }
}

actor CancelGate {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private(set) var waiting = false
    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }
    func sleep() async throws {
        waiting = true
        for await _ in stream { break }
        try Task.checkCancellation()
    }
}

@Test func cancelledGotoStopsAndReleasesItsLease() async throws {
    let clock = ManualClock()
    let dev = LaggedPoseDevice(clock: clock)
    let c = GimbalController(device: dev, policy: makePolicy(), now: { clock.now() })
    let gate = CancelGate()
    let nav = GotoNavigator(controller: c, clock: RuntimeClock(now: { clock.now() }, sleep: { _ in try await gate.sleep() }))
    let lease = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 30)
    let task = Task { try await nav.go(to: "mesa", source: lease.source, lease: lease) }
    while !(await gate.waiting) { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await dev.sent.last?.1 == .stop)
    #expect(await c.activeLease == nil)
}

actor PulseCancelGate {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private(set) var waiting = false
    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }
    func holdPulse() async throws {
        waiting = true
        for await _ in stream { break }
        try Task.checkCancellation()
    }
}
@Test func cancellationDuringSpeedPulseLeavesStopAsLastCommand() async throws {
    let clock = ManualClock()
    let dev = LaggedPoseDevice(clock: clock, pose: Pose(yaw: -8))
    let zone = Zone(name: "mesa", yaw: -12...12, pitch: -12...12)
    let c = GimbalController(device: dev, policy: makePolicy(zones: [zone]), now: { clock.now() })
    let gate = PulseCancelGate()
    let timing = RuntimeClock(now: { clock.now() }, sleep: { seconds in
        if seconds >= 0.3 { try await gate.holdPulse() }
        else { await dev.advance(seconds); await c.tick(); try Task.checkCancellation() }
    })
    let nav = GotoNavigator(controller: c, clock: timing)
    let lease = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 30)
    let task = Task { try await nav.go(to: "mesa", source: lease.source, lease: lease) }
    while !(await gate.waiting) { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    await dev.advance(0.2)
    #expect(await dev.sent.last?.1 == .stop)
    #expect(await dev.truePoses.allSatisfy { zone.contains($0) })
    #expect(await c.activeLease == nil)
}

extension GatedPoseDevice: PoseFeedbackDevice {
    func poseSample() async -> PoseSample? {
        guard let pose = await currentPose() else { return nil }
        return PoseSample(pose: pose, receivedAt: Date(timeIntervalSince1970: 1_000_000), sequence: 1)
    }
}
@Test func cancellationStopsEvenWhenFeedbackReadIsSuspended() async throws {
    let clock = ManualClock()
    let dev = GatedPoseDevice()
    let c = GimbalController(device: dev, policy: makePolicy(), now: { clock.now() })
    let nav = GotoNavigator(controller: c, clock: RuntimeClock(now: { clock.now() }, sleep: { _ in
        try Task.checkCancellation()
    }))
    let lease = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 30)
    let task = Task { try await nav.go(to: "mesa", source: lease.source, lease: lease) }
    while !(await dev.isWaiting) { await Task.yield() }
    task.cancel()
    while await dev.commands.last != .stop { await Task.yield() }
    #expect(await c.activeLease == nil)
    await dev.open()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await dev.commands == [.stop])
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter 'gotoWithLag|frozenPose|cancelledGoto'`
Expected: faltan `GotoNavigator` y `LaggedPoseDevice`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKit/GotoNavigator.swift`:
```swift
import Foundation

public actor GotoNavigator {
    private let controller: GimbalController
    private let clock: RuntimeClock
    private let limits = NavigationLimits()
    private var running = false
    public init(controller: GimbalController, clock: RuntimeClock = .live) {
        self.controller = controller; self.clock = clock
    }
    public func go(to zoneName: String, source: ControlSource, lease: Lease) async throws -> Pose {
        guard !running else { throw NavigationError.busy }
        guard lease.zone == zoneName, lease.source == source else { throw SafetyViolation.noLease }
        running = true
        defer { running = false }
        return try await withTaskCancellationHandler {
            do {
                let deadline = clock.now().addingTimeInterval(limits.timeoutSeconds)
                while true {
                    try Task.checkCancellation()
                    guard clock.now() < deadline else { throw NavigationError.timeout }
                    let initial = try await controller.navigationContext(source: source, lease: lease)
                    try await controller.haltNavigation(lease: lease)
                    let stoppedAt = clock.now()
                    let context = try await settled(after: initial.sample.sequence, stoppedAt: stoppedAt,
                                                    deadline: deadline, source: source, lease: lease)
                    let center = Pose(yaw: (context.zone.yaw.lowerBound + context.zone.yaw.upperBound) / 2,
                                      pitch: (context.zone.pitch.lowerBound + context.zone.pitch.upperBound) / 2)
                    let dy = center.yaw - context.sample.pose.yaw
                    let dp = center.pitch - context.sample.pose.pitch
                    if abs(dy) <= limits.deadband && abs(dp) <= limits.deadband {
                        try Task.checkCancellation()
                        await controller.audit.record(AuditEntry(date: clock.now(), source: source,
                                                                event: "goto \(zoneName)", outcome: .accepted))
                        try Task.checkCancellation()
                        guard clock.now() < deadline else { throw NavigationError.timeout }
                        return context.sample.pose
                    }
                    func speed(_ error: Double) -> Double {
                        abs(error) <= limits.deadband ? 0 : max(-limits.maxSpeed, min(limits.maxSpeed, error * limits.gain))
                    }
                    let velocity = Pose(yaw: speed(dy), pitch: speed(dp))
                    guard clock.now().addingTimeInterval(limits.pulseSeconds + limits.brakingSeconds) < deadline else {
                        throw NavigationError.timeout
                    }
                    try NavigationSafety.check(pose: context.sample.pose, velocity: velocity, zone: context.zone,
                                               forbidden: context.forbidden, limits: limits)
                    try await controller.navigationPulse(velocity, source: source, lease: lease)
                    try await clock.sleep(limits.pulseSeconds)
                    try await controller.haltNavigation(lease: lease)
                }
            } catch {
                await controller.release(lease: lease)
                let reason = Task.isCancelled ? "cancelled" : String(String(describing: error).prefix { $0 != "(" })
                await controller.audit.record(AuditEntry(date: clock.now(), source: source,
                                                        event: "goto \(zoneName)", outcome: .rejected(reason)))
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            // La lectura de pose puede estar suspendida: parar sin esperar a que termine.
            // release compara UUID; una limpieza tardía no revoca una concesión nueva.
            Task { await self.controller.release(lease: lease) }
        }
    }
    private func settled(after initial: UInt64, stoppedAt: Date, deadline: Date,
                         source: ControlSource, lease: Lease) async throws -> NavigationContext {
        var mark = initial
        var newSamples = 0
        while true {
            try Task.checkCancellation()
            guard clock.now() < deadline else { throw NavigationError.timeout }
            let context = try await controller.navigationContext(source: source, lease: lease)
            guard clock.now() < deadline else { throw NavigationError.timeout }
            if context.sample.sequence != mark {
                mark = context.sample.sequence
                if context.sample.receivedAt >= stoppedAt { newSamples += 1 }
            }
            if newSamples >= 2,
               context.sample.receivedAt.timeIntervalSince(stoppedAt) >= limits.settleSeconds { return context }
            try await clock.sleep(0.1)
        }
    }
}
```

`Sources/GimbalKitSim/LaggedPoseDevice.swift`:
```swift
import Foundation
import GimbalKit

/// Retardo 0,7 s, muestreo 0,7 s, ganancia física 1,25 y frenado conservador 0,20 s.
public actor LaggedPoseDevice: PoseFeedbackDevice {
    public nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    private let sim: SimGimbal
    private let clock: ManualClock
    private var sample: PoseSample
    private var captured: Pose
    private var elapsed = 0.0
    private var immobile = false
    private var physicalVelocity = Pose()
    private var brakingRemaining = 0.0
    public private(set) var frozen = false
    public private(set) var truePoses: [Pose] = []
    public private(set) var sent: [(Date, MoveCommand)] = []
    public init(clock: ManualClock, pose: Pose = Pose()) {
        self.clock = clock; sim = SimGimbal(capabilities: [.speedControl, .poseFeedback], pose: pose)
        captured = pose; sample = PoseSample(pose: pose, receivedAt: clock.now(), sequence: 0)
    }
    public func setFrozen(_ value: Bool) { frozen = value }
    public func setImmobile(_ value: Bool) { immobile = value }
    public func currentPose() -> Pose? { sample.pose }
    public func poseSample() -> PoseSample? { sample }
    public func send(_ command: MoveCommand) async throws {
        sent.append((clock.now(), command))
        switch command {
        case let .speed(y, p, r):
            brakingRemaining = 0
            physicalVelocity = Pose(yaw: y * 1.25, pitch: p * 1.25, roll: r * 1.25)
            try await sim.send(.speed(yaw: physicalVelocity.yaw, pitch: physicalVelocity.pitch, roll: physicalVelocity.roll))
        case .stop:
            if physicalVelocity != Pose() { brakingRemaining = 0.2 }
            else { try await sim.send(.stop) }
        case .absolute: throw SafetyViolation.unsupported(.absoluteControl)
        }
    }
    public func advance(_ seconds: Double) async {
        var remaining = seconds
        while remaining > 1e-9 {
            let step = min(0.1, remaining, brakingRemaining > 1e-9 ? brakingRemaining : remaining)
            clock.advance(step)
            if !immobile { await sim.advance(seconds: step) }
            let pose = await sim.pose
            truePoses.append(pose)
            elapsed += step
            if elapsed >= 0.7 - 1e-9 {
                elapsed -= 0.7
                if !frozen {
                    sample = PoseSample(pose: captured, receivedAt: clock.now(), sequence: sample.sequence &+ 1)
                    captured = pose
                }
            }
            if brakingRemaining > 0 {
                brakingRemaining -= step
                if brakingRemaining <= 1e-9 {
                    brakingRemaining = 0; physicalVelocity = Pose(); try? await sim.send(.stop)
                }
            }
            remaining -= step
        }
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: éxito con retardo, ganancia y frenado conservadores; timeout/congelación avanzan solo reloj manual; cancelación durante asentamiento, con SPEED activo y en lectura suspendida envía parada sin espera real. No hay `.absolute`; tras éxito permanece el lease hasta `tick()`.

- [ ] **Step 5: Commit** (Claude): `feat: ir al centro de zona con pulsos y pose retardada`

---

### Task 4: ZoneStore y archivos locales privados

**Files:**
- Create: `Sources/GimbalKit/ZoneStore.swift`, `Sources/GimbalKitMCP/LocalFiles.swift`
- Modify: `Package.swift` (sustituir por el manifiesto de este paso)
- Test: `Tests/GimbalKitTests/ZoneStoreTests.swift`, `Tests/GimbalKitMCPTests/LocalFilesTests.swift`

**Interfaces:**
- Consumes: `Zone` actual (`Codable`), Foundation y Security/Darwin del sistema.
- Produces: `ZoneStore.init(url: URL = ZoneStore.defaultURL)`, `load() throws -> [Zone]`, `save(_ zones: [Zone]) throws`; `ZoneRecord.init(_ zone: Zone)`, `zone() throws -> Zone`; `LocalFiles.init(directory: URL = LocalFiles.defaultDirectory) throws`, `token(create: Bool) throws -> String`, `writeEndpoint(port: UInt16) throws`, `readEndpoint() throws -> UInt16`, `removeEndpoint() throws`; `LocalFileError` y `ZoneStoreError` tipados.

- [ ] **Step 1: Escribir las pruebas que fallan y registrar el target**

`Package.swift` (en este paso el target nuevo tiene su test y el fichero de implementación del Step 3):
```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "GimbalKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GimbalKit", targets: ["GimbalKit"]),
        .library(name: "GimbalKitSim", targets: ["GimbalKitSim"]),
        .library(name: "GimbalKitDJI", targets: ["GimbalKitDJI"]),
        .library(name: "GimbalKitBLE", targets: ["GimbalKitBLE"]),
        .library(name: "GimbalKitMCP", targets: ["GimbalKitMCP"]),
    ],
    targets: [
        .target(name: "GimbalKit"),
        .target(name: "GimbalKitSim", dependencies: ["GimbalKit"]),
        .target(name: "GimbalKitDJI", dependencies: ["GimbalKit"]),
        .target(name: "GimbalKitBLE", dependencies: ["GimbalKitDJI"]),
        .target(name: "GimbalKitMCP", dependencies: ["GimbalKit"]),
        .executableTarget(name: "GimbalSmoke", dependencies: ["GimbalKitBLE", "GimbalKitDJI", "GimbalKit"]),
        .testTarget(name: "GimbalKitTests", dependencies: ["GimbalKit", "GimbalKitSim"]),
        .testTarget(name: "GimbalKitDJITests", dependencies: ["GimbalKitDJI", "GimbalKit"]),
        .testTarget(name: "GimbalKitMCPTests", dependencies: ["GimbalKitMCP", "GimbalKit"]),
    ]
)
```

`Tests/GimbalKitTests/ZoneStoreTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit

@Test func zoneStoreRoundTripAndCorruptBackup() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("zones.json")
    let store = ZoneStore(url: url)
    #expect(try await store.load().isEmpty)
    let zones = [Zone(name: "mesa", yaw: -10...10, pitch: -10...10)]
    try await store.save(zones)
    #expect(try await store.load() == zones)
    await #expect(throws: ZoneStoreError.invalidZone) { try await store.save(zones + zones) }
    #expect(try await store.load() == zones)
    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: url)
    #expect(try await store.load().isEmpty)
    #expect(try Data(contentsOf: url.appendingPathExtension("bak")) == corrupt)
    try await store.save(zones)
    #expect(try await store.load() == zones)
}
```

`Tests/GimbalKitMCPTests/LocalFilesTests.swift`:
```swift
import Foundation
import Darwin
import Testing
@testable import GimbalKitMCP

@Test func tokenIsPrivateStableRandomAndRejectsSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try LocalFiles(directory: root)
    #expect(throws: LocalFileError.missing) { try files.token(create: false) }
    let token = try files.token(create: true)
    #expect(token.utf8.count == 64 && token.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(try files.token(create: false) == token)
    let url = root.appendingPathComponent("token")
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try files.writeEndpoint(port: 12345)
    #expect(try files.readEndpoint() == 12345)
    try files.removeEndpoint()
    #expect(throws: LocalFileError.missing) { try files.readEndpoint() }
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("other"))
    #expect(throws: LocalFileError.unsafeFile) { try files.token(create: true) }
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: target vacío todavía y/o símbolos nuevos inexistentes; esta es la fase roja, no crear un fichero marcador.

- [ ] **Step 3: Implementar**

`Sources/GimbalKit/ZoneStore.swift`:
```swift
import Foundation

public enum ZoneStoreError: Error, Sendable, Equatable { case invalidZone }
public struct ZoneRecord: Sendable, Codable, Equatable {
    public let name: String
    public let yawLower: Double
    public let yawUpper: Double
    public let pitchLower: Double
    public let pitchUpper: Double
    public let forbidden: Bool
    public init(_ zone: Zone) {
        name = zone.name; yawLower = zone.yaw.lowerBound; yawUpper = zone.yaw.upperBound
        pitchLower = zone.pitch.lowerBound; pitchUpper = zone.pitch.upperBound; forbidden = zone.forbidden
    }
    public func zone() throws -> Zone {
        guard !name.isEmpty, name.count <= 64, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              [yawLower, yawUpper, pitchLower, pitchUpper].allSatisfy(\.isFinite),
              yawLower < yawUpper, pitchLower < pitchUpper,
              yawLower >= -180, yawUpper <= 180, pitchLower >= -90, pitchUpper <= 90 else {
            throw ZoneStoreError.invalidZone
        }
        return Zone(name: name, yaw: yawLower...yawUpper, pitch: pitchLower...pitchUpper, forbidden: forbidden)
    }
}
public actor ZoneStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GimbalKit/zones.json")
    }
    private struct Document: Codable { let version: Int; let zones: [ZoneRecord] }
    private let url: URL
    public init(url: URL = ZoneStore.defaultURL) { self.url = url }
    public func load() throws -> [Zone] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        do {
            guard data.count <= 1_048_576 else { throw ZoneStoreError.invalidZone }
            let doc = try JSONDecoder().decode(Document.self, from: data)
            guard doc.version == 1 else { throw ZoneStoreError.invalidZone }
            let zones = try doc.zones.map { try $0.zone() }
            try validate(zones)
            return zones
        } catch {
            // Preservar los bytes corruptos; un error de E/S al hacer backup sí se informa.
            try data.write(to: url.appendingPathExtension("bak"), options: .atomic)
            return []
        }
    }
    public func save(_ zones: [Zone]) throws {
        try validate(zones)
        let data = try JSONEncoder().encode(Document(version: 1, zones: zones.map(ZoneRecord.init)))
        guard data.count <= 1_048_576 else { throw ZoneStoreError.invalidZone }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    private func validate(_ zones: [Zone]) throws {
        guard zones.count <= 256, Set(zones.map(\.name)).count == zones.count else { throw ZoneStoreError.invalidZone }
        for zone in zones { _ = try ZoneRecord(zone).zone() }
    }
}
```

`Sources/GimbalKitMCP/LocalFiles.swift` (macOS; el target se condicionará en el manifiesto final):
```swift
import Foundation
import Security
import Darwin

public enum LocalFileError: Error, Sendable, Equatable { case missing, unsafeFile, io, random }
public struct LocalFiles: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GimbalKit")
    }
    public let directory: URL
    public init(directory: URL = LocalFiles.defaultDirectory) throws {
        self.directory = directory
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { throw LocalFileError.unsafeFile }
    }
    public func token(create: Bool) throws -> String {
        let path = directory.appendingPathComponent("token").path
        if create {
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 {
                var random = [UInt8](repeating: 0, count: 32)
                let rc = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
                guard rc == errSecSuccess else { close(fd); unlink(path); throw LocalFileError.random }
                let value = random.map { String(format: "%02x", $0) }.joined()
                do { try writeAll(Data(value.utf8), fd: fd); guard fsync(fd) == 0 else { throw LocalFileError.io } }
                catch { close(fd); unlink(path); throw error }
                close(fd)
            } else if errno != EEXIST { throw LocalFileError.unsafeFile }
        }
        let data = try readPrivate(path, maxBytes: 64)
        guard let value = String(data: data, encoding: .utf8), value.utf8.count == 64,
              value.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw LocalFileError.unsafeFile }
        return value
    }
    public func writeEndpoint(port: UInt16) throws {
        guard port > 0 else { throw LocalFileError.unsafeFile }
        let data = try JSONEncoder().encode(["port": port])
        let temp = directory.appendingPathComponent(".endpoint-\(UUID().uuidString)").path
        let destination = directory.appendingPathComponent("endpoint.json").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalFileError.io }
        defer { close(fd); unlink(temp) }
        try writeAll(data, fd: fd)
        guard fsync(fd) == 0, rename(temp, destination) == 0 else { throw LocalFileError.io }
    }
    public func readEndpoint() throws -> UInt16 {
        let data = try readPrivate(directory.appendingPathComponent("endpoint.json").path, maxBytes: 128)
        guard let port = try JSONDecoder().decode([String: UInt16].self, from: data)["port"], port > 0 else {
            throw LocalFileError.unsafeFile
        }
        return port
    }
    public func removeEndpoint() throws {
        if unlink(directory.appendingPathComponent("endpoint.json").path) != 0, errno != ENOENT { throw LocalFileError.io }
    }
    private func readPrivate(_ path: String, maxBytes: Int) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? LocalFileError.missing : LocalFileError.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o777 == 0o600,
              info.st_size >= 0, info.st_size <= maxBytes else { throw LocalFileError.unsafeFile }
        var bytes = [UInt8](repeating: 0, count: maxBytes + 1)
        var total = 0
        while total < bytes.count {
            let capacity = bytes.count - total
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: total), capacity) }
            if n < 0 { if errno == EINTR { continue }; throw LocalFileError.io }
            if n == 0 { break }
            total += n
        }
        guard total <= maxBytes else { throw LocalFileError.unsafeFile }
        return Data(bytes.prefix(total))
    }
    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw LocalFileError.io }
                guard n > 0 else { throw LocalFileError.io }
                offset += n
            }
        }
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: roundtrip, backup byte a byte, duplicados sin sobrescritura y token 0600 pasan; las pruebas solo escriben en temporales. El token de la persona no se crea ni se imprime en pruebas.

- [ ] **Step 5: Commit** (Claude): `feat: zonas atómicas y token local privado`

---

### Task 5: GimbalService, JSON-RPC y herramientas cerradas

**Files:**
- Create: `Sources/GimbalKitMCP/GimbalService.swift`, `Sources/GimbalKitMCP/JSONValue.swift`, `Sources/GimbalKitMCP/MCPDispatcher.swift`
- Test: `Tests/GimbalKitMCPTests/DispatcherTests.swift`

**Interfaces:**
- Consumes: `Pose`, `ZoneRecord`, `NavigationError` y errores del núcleo; ningún transporte.
- Produces: `protocol GimbalService: Sendable { func status() async throws -> GimbalStatus; func zones() async throws -> [ZoneRecord]; func look(zone: String, leaseSeconds: Double) async throws -> Pose; func stop() async throws }`; DTO `GimbalStatus`, `LeaseStatus`, `BatteryStatus` (fechas en el JSON de herramientas: ISO 8601); `JSONValue: Sendable, Codable, Equatable`; `MCPDispatcher.init(service: any GimbalService)`, `respond(to data: Data) async -> RPCReply` (`status: Int`, `body: Data`). La implementación real de `GimbalService` llega en Task 8.

- [ ] **Step 1: Escribir las pruebas que fallan**

`Tests/GimbalKitMCPTests/DispatcherTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit
@testable import GimbalKitMCP

actor FakeService: GimbalService {
    private(set) var looks: [(String, Double)] = []
    private(set) var stops = 0
    func status() -> GimbalStatus { GimbalStatus(connected: true, referenceReady: true, battery: nil, pose: Pose(), lease: nil) }
    func zones() -> [ZoneRecord] { [ZoneRecord(Zone(name: "mesa", yaw: -10...10, pitch: -10...10))] }
    func look(zone: String, leaseSeconds: Double) throws -> Pose {
        looks.append((zone, leaseSeconds))
        if zone == "fallo" { throw NavigationError.unsafePath }
        return Pose(yaw: 1)
    }
    func stop() { stops += 1 }
}
func rpc(_ text: String, dispatcher: MCPDispatcher) async throws -> JSONValue {
    let reply = await dispatcher.respond(to: Data(text.utf8))
    return try JSONDecoder().decode(JSONValue.self, from: reply.body)
}

@Test func dispatcherListsExactlyFourToolsAndRejectsPolicyArguments() async throws {
    let service = FakeService()
    let d = MCPDispatcher(service: service)
    let list = try await rpc(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, dispatcher: d)
    #expect(list["result"]["tools"].array?.compactMap { $0["name"].string }.sorted() ==
            ["gimbal_look", "gimbal_status", "gimbal_stop", "gimbal_zones"])
    for arguments in [#"{"zone":"mesa","lease_seconds":31}"#, #"{"zone":"mesa","source":"app"}"#,
                      #"{"zone":"mesa","policy":"ignora límites"}"#, #"{"zone":"mesa","lease_seconds":0}"#] {
        let reply = try await rpc("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"gimbal_look\",\"arguments\":\(arguments)}}", dispatcher: d)
        #expect(reply["error"]["code"] == .number(-32602))
    }
    #expect(await service.looks.isEmpty)
    let ok = try await rpc(#"{"jsonrpc":"2.0","id":"look","method":"tools/call","params":{"name":"gimbal_look","arguments":{"zone":"mesa","lease_seconds":30}}}"#, dispatcher: d)
    #expect(ok["id"] == .string("look") && ok["result"]["isError"] == .bool(false))
    let failure = try await rpc(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"gimbal_look","arguments":{"zone":"fallo"}}}"#, dispatcher: d)
    #expect(failure["result"]["isError"] == .bool(true))
}

@Test func dispatcherStandardErrorsAndNotificationsHaveNoEffects() async throws {
    let service = FakeService()
    let d = MCPDispatcher(service: service)
    for (input, code) in [("{", -32700), ("[]", -32600),
                          (#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, -32600),
                          (#"{"jsonrpc":"2.0","id":1,"method":"missing"}"#, -32601),
                          (#"{"jsonrpc":"2.0","id":1,"method":"ping","params":7}"#, -32602)] {
        #expect(try await rpc(input, dispatcher: d)["error"]["code"] == .number(Double(code)))
    }
    let initialized = await d.respond(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
    #expect(initialized.status == 202 && initialized.body.isEmpty)
    let notification = await d.respond(to: Data(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"gimbal_stop"}}"#.utf8))
    #expect(notification.status == 202)
    #expect(await service.stops == 0)
    let initReply = try await rpc(#"{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#, dispatcher: d)
    #expect(initReply["result"]["protocolVersion"] == .string("2025-03-26"))
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter 'dispatcherLists|dispatcherStandard'`
Expected: tipos y dispatcher inexistentes.

- [ ] **Step 3: Implementar**

`Sources/GimbalKitMCP/GimbalService.swift`:
```swift
import Foundation
import GimbalKit

public struct BatteryStatus: Sendable, Codable, Equatable {
    public let percent: Int
    public let charging: Bool
    public init(percent: Int, charging: Bool) { self.percent = percent; self.charging = charging }
}
public struct LeaseStatus: Sendable, Codable, Equatable {
    public let zone: String
    public let expiresAt: Date
    public init(zone: String, expiresAt: Date) { self.zone = zone; self.expiresAt = expiresAt }
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
public protocol GimbalService: Sendable {
    func status() async throws -> GimbalStatus
    func zones() async throws -> [ZoneRecord]
    func look(zone: String, leaseSeconds: Double) async throws -> Pose
    func stop() async throws
}
```

`Sources/GimbalKitMCP/JSONValue.swift`:
```swift
import Foundation

public enum JSONValue: Sendable, Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .object(o): try c.encode(o)
        case let .array(a): try c.encode(a)
        case let .string(s): try c.encode(s)
        case let .number(n): try c.encode(n)
        case let .bool(b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public var object: [String: JSONValue]? { if case let .object(o) = self { o } else { nil } }
    public var array: [JSONValue]? { if case let .array(a) = self { a } else { nil } }
    public var string: String? { if case let .string(s) = self { s } else { nil } }
    public var number: Double? { if case let .number(n) = self { n } else { nil } }
    public static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}
```

`Sources/GimbalKitMCP/MCPDispatcher.swift`:
```swift
import Foundation
import GimbalKit

public struct RPCReply: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}
private enum RPCFailure: Error { case method, params }
public struct MCPDispatcher: Sendable {
    private let service: any GimbalService
    public init(service: any GimbalService) { self.service = service }
    public static let versions = ["2025-03-26", "2025-06-18"]
    public func respond(to data: Data) async -> RPCReply {
        let request: JSONValue
        do { request = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { return error(-32700, "Parse error", id: .null) }
        guard let object = request.object, request["jsonrpc"] == .string("2.0"),
              let method = request["method"].string,
              Set(object.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]),
              validID(object["id"]) else { return error(-32600, "Invalid Request", id: .null) }
        // Una notificación jamás ejecuta una herramienta, incluso si dice tools/call.
        guard let id = object["id"] else { return RPCReply(status: 202, body: Data()) }
        let params = object["params"] ?? .object([:])
        do {
            guard let p = params.object else { throw RPCFailure.params }
            let result: JSONValue
            switch method {
            case "initialize":
                guard Set(p.keys) == ["protocolVersion", "capabilities", "clientInfo"],
                      let requested = p["protocolVersion"]?.string, p["capabilities"]?.object != nil,
                      let info = p["clientInfo"]?.object, info["name"]?.string != nil, info["version"]?.string != nil else {
                    throw RPCFailure.params
                }
                result = .object(["protocolVersion": .string(Self.versions.contains(requested) ? requested : Self.versions[0]),
                                  "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                                  "serverInfo": .object(["name": .string("GimbalKit"), "version": .string("1.0")])])
            case "ping":
                guard p.isEmpty else { throw RPCFailure.params }; result = .object([:])
            case "tools/list":
                guard p.isEmpty else { throw RPCFailure.params }; result = .object(["tools": .array(Self.tools)])
            case "tools/call": result = try await call(p)
            default: throw RPCFailure.method
            }
            return reply(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
        } catch RPCFailure.method { return error(-32601, "Method not found", id: id) }
        catch RPCFailure.params { return error(-32602, "Invalid params", id: id) }
        catch { return error(-32603, "Internal error", id: id) }
    }
    private func validID(_ id: JSONValue?) -> Bool {
        switch id {
        case nil, .null?, .string?: true
        case let .number(n)?: n.isFinite && n.rounded() == n && abs(n) <= 9_007_199_254_740_991
        default: false
        }
    }
    private func call(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard Set(p.keys).isSubset(of: ["name", "arguments"]), let name = p["name"]?.string,
              let args = (p["arguments"] ?? .object([:])).object else { throw RPCFailure.params }
        guard ["gimbal_status", "gimbal_zones", "gimbal_look", "gimbal_stop"].contains(name) else { throw RPCFailure.params }
        if name == "gimbal_look" {
            guard Set(args.keys).isSubset(of: ["zone", "lease_seconds"]),
                  let zone = args["zone"]?.string, !zone.isEmpty, zone.count <= 64,
                  args["lease_seconds"] == nil || args["lease_seconds"]?.number != nil else { throw RPCFailure.params }
            let seconds = args["lease_seconds"]?.number ?? 30
            guard seconds.isFinite, seconds > 0, seconds <= 30 else { throw RPCFailure.params }
        } else if !args.isEmpty { throw RPCFailure.params }
        do {
            let value: JSONValue
            switch name {
            case "gimbal_status": value = try JSONValue.encoded(await service.status())
            case "gimbal_zones": value = .object(["zones": try JSONValue.encoded(await service.zones())])
            case "gimbal_look": value = try JSONValue.encoded(await service.look(zone: args["zone"]!.string!, leaseSeconds: args["lease_seconds"]?.number ?? 30))
            default: try await service.stop(); value = .object(["stopped": .bool(true)])
            }
            return try toolResult(value, isError: false)
        } catch {
            // No incluir errores arbitrarios del driver, paths ni credenciales.
            let code: String
            if error is CancellationError { code = "cancelled" }
            else if let e = error as? NavigationError { code = String(describing: e) }
            else if let e = error as? SafetyViolation { code = String(String(describing: e).prefix { $0 != "(" }) }
            else { code = "deviceUnavailable" }
            return try toolResult(.object(["error": .string(code)]), isError: true)
        }
    }
    private func toolResult(_ value: JSONValue, isError: Bool) throws -> JSONValue {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        return .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                        "structuredContent": value, "isError": .bool(isError)])
    }
    private func reply(_ value: JSONValue) -> RPCReply {
        do { return RPCReply(status: 200, body: try JSONEncoder().encode(value)) }
        catch { return RPCReply(status: 200, body: Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)) }
    }
    private func error(_ code: Int, _ message: String, id: JSONValue) -> RPCReply {
        reply(.object(["jsonrpc": .string("2.0"), "id": id,
                       "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }
    private static var tools: [JSONValue] {
        ["gimbal_status", "gimbal_zones", "gimbal_look", "gimbal_stop"].map { name in
            let properties: [String: JSONValue] = name == "gimbal_look" ? [
                "zone": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(64)]),
                "lease_seconds": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(30), "default": .number(30)])
            ] : [:]
            return .object(["name": .string(name), "description": .string(name),
                            "inputSchema": .object(["type": .string("object"), "properties": .object(properties),
                                                     "required": .array(name == "gimbal_look" ? [.string("zone")] : []),
                                                     "additionalProperties": .bool(false)])])
        }
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: cuatro herramientas exactas; argumentos extra, lease inválido y método desconocido rechazados; initialized 202; notificaciones de tools/call sin efectos. Transporte stateless: no sesiones ni SSE, negociación de versión explícita.

- [ ] **Step 5: Commit** (Claude): `feat: servicio MCP tipado y herramientas sin cambios de política`

---

### Task 6: Parser HTTP incremental y controles de acceso

**Files:**
- Create: `Sources/GimbalKitMCP/HTTPParser.swift`
- Test: `Tests/GimbalKitMCPTests/HTTPParserTests.swift`

**Interfaces:**
- Consumes: bytes `Data`, token hexadecimal de Task 4 y versiones de Task 5.
- Produces: `HTTPRequest: Sendable`, `HTTPFailure.init(_ status: Int)`, `HTTPParser.init()`, `mutating func feed(_ data: Data) throws -> HTTPRequest?`; `HTTPGate.init(port: UInt16, token: String)`, `validate(_ request: HTTPRequest) throws`; `ConstantTime.equal(_ presented: String, _ expected: String) -> Bool`. Máximos: cabecera 8192 B/64 campos, cuerpo 65536 B, una petición por conexión, sin chunked ni pipelining.

- [ ] **Step 1: Escribir las pruebas que fallan**

`Tests/GimbalKitMCPTests/HTTPParserTests.swift`:
```swift
import Foundation
import Testing
@testable import GimbalKitMCP

let testToken = String(repeating: "a", count: 64)
func requestData(host: String = "127.0.0.1:12345", origin: String? = nil,
                 auth: String? = "Bearer " + testToken, extra: String = "", body: String = "{}") -> Data {
    var text = "POST /mcp HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\nAccept: application/json\r\n"
    if let origin { text += "Origin: \(origin)\r\n" }
    if let auth { text += "Authorization: \(auth)\r\n" }
    text += extra + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
    return Data(text.utf8)
}
func parsed(_ data: Data) throws -> HTTPRequest {
    var parser = HTTPParser()
    return try #require(parser.feed(data))
}

@Test func fragmentedRequestParsesAndOnlyLocalAuthenticatedOriginsPass() throws {
    let data = requestData()
    var parser = HTTPParser()
    var result: HTTPRequest?
    for byte in data { if let r = try parser.feed(Data([byte])) { result = r } }
    let gate = HTTPGate(port: 12345, token: testToken)
    try gate.validate(try #require(result))
    try gate.validate(parsed(requestData(host: "localhost:12345", origin: "http://localhost:12345")))
    for host in ["evil.test:12345", "localhost.evil:12345", "127.1:12345", "127.0.0.1:99", "[::1]:12345"] {
        #expect(throws: HTTPFailure(403)) { try gate.validate(parsed(requestData(host: host))) }
    }
    for origin in ["null", "https://evil.test", "http://127.0.0.1:99", "http://localhost:12345/evil"] {
        #expect(throws: HTTPFailure(403)) { try gate.validate(parsed(requestData(origin: origin))) }
    }
    for auth in [nil, "Bearer " + String(repeating: "b", count: 64), "Bearer " + testToken + "a"] {
        #expect(throws: HTTPFailure(401)) { try gate.validate(parsed(requestData(auth: auth))) }
    }
    #expect(ConstantTime.equal(testToken, testToken))
    #expect(!ConstantTime.equal("b" + String(testToken.dropFirst()), testToken))
    #expect(!ConstantTime.equal(String(testToken.dropLast()) + "b", testToken))
    #expect(!ConstantTime.equal(testToken + String(repeating: "x", count: 256), testToken))
}

@Test func parserRejectsSmugglingOversizeAndMalformedLengths() throws {
    for extra in ["Content-Length: 2\r\n", "Transfer-Encoding: chunked\r\n", " Host: evil\r\n", "Host : evil\r\n"] {
        #expect(throws: HTTPFailure(400)) { try parsed(requestData(extra: extra)) }
    }
    for value in ["-1", "+2", "999999999999999999999999999", "2,2"] {
        let data = Data("POST /mcp HTTP/1.1\r\nHost: localhost:12345\r\nContent-Length: \(value)\r\n\r\n".utf8)
        #expect(throws: HTTPFailure.self) { try parsed(data) }
    }
    #expect(throws: HTTPFailure(413)) { try parsed(requestData(body: String(repeating: "x", count: 65537))) }
    #expect(throws: HTTPFailure(431)) { try parsed(requestData(extra: "X: " + String(repeating: "x", count: 8192) + "\r\n")) }
    #expect(throws: HTTPFailure(400)) { try parsed(requestData() + requestData()) }
    var partial = HTTPParser()
    #expect(try partial.feed(Data("POST /mcp HTTP/1.1\r\n".utf8)) == nil)
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter 'fragmentedRequest|parserRejects'`
Expected: no existen parser/gate.

- [ ] **Step 3: Implementar**

`Sources/GimbalKitMCP/HTTPParser.swift`:
```swift
import Foundation

public struct HTTPFailure: Error, Sendable, Equatable {
    public let status: Int
    public init(_ status: Int) { self.status = status }
}
public struct HTTPRequest: Sendable {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: Data
}
public struct HTTPParser: Sendable {
    private var buffer = Data()
    private var header: (String, String, [String: String], Int, Int)?
    private var completed = false
    public init() {}
    public mutating func feed(_ data: Data) throws -> HTTPRequest? {
        guard !completed else { throw HTTPFailure(400) }
        guard data.count <= 8192 + 65536, buffer.count <= 8192 + 65536 - data.count else { throw HTTPFailure(413) }
        buffer.append(data)
        if header == nil {
            guard let delimiter = buffer.range(of: Data([13, 10, 13, 10])) else {
                guard buffer.count <= 8192 else { throw HTTPFailure(431) }
                return nil
            }
            let end = delimiter.upperBound
            guard end <= 8192 else { throw HTTPFailure(431) }
            let bytes = buffer[..<delimiter.lowerBound]
            guard bytes.allSatisfy({ $0 == 13 || $0 == 10 || $0 == 9 || (32...126).contains($0) }),
                  let text = String(data: bytes, encoding: .ascii) else { throw HTTPFailure(400) }
            let lines = text.components(separatedBy: "\r\n")
            guard lines.count <= 65 else { throw HTTPFailure(431) }
            let requestLine = lines[0].components(separatedBy: " ")
            guard requestLine.count == 3, requestLine[2] == "HTTP/1.1",
                  !requestLine[0].isEmpty, !requestLine[1].isEmpty else { throw HTTPFailure(400) }
            var fields: [String: String] = [:]
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~".utf8)
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw HTTPFailure(400) }
                let name = String(line[..<colon])
                guard !name.isEmpty, name.utf8.allSatisfy({ allowed.contains($0) }) else { throw HTTPFailure(400) }
                let key = name.lowercased()
                let raw = line[line.index(after: colon)...]
                guard !raw.contains("\r"), !raw.contains("\n"), fields[key] == nil else { throw HTTPFailure(400) }
                fields[key] = raw.trimmingCharacters(in: .whitespaces)
            }
            guard fields["transfer-encoding"] == nil else { throw HTTPFailure(400) }
            guard let lengthText = fields["content-length"] else { throw HTTPFailure(411) }
            guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(lengthText) else { throw HTTPFailure(400) }
            guard length <= 65536 else { throw HTTPFailure(413) }
            header = (requestLine[0], requestLine[1], fields, end, length)
        }
        guard let (method, target, fields, end, length) = header else { return nil }
        guard buffer.count >= end + length else { return nil }
        guard buffer.count == end + length else { throw HTTPFailure(400) }
        completed = true
        return HTTPRequest(method: method, target: target, headers: fields, body: Data(buffer[end...]))
    }
}
public enum ConstantTime {
    public static func equal(_ presented: String, _ expected: String) -> Bool {
        let a = Array(presented.utf8), b = Array(expected.utf8)
        var difference = UInt64(a.count ^ b.count)
        // El número de iteraciones solo depende de la longitud pública del formato del token.
        for i in b.indices { difference |= UInt64((i < a.count ? a[i] : 0) ^ b[i]) }
        return difference == 0
    }
}
public struct HTTPGate: Sendable {
    private let port: UInt16
    private let token: String
    public init(port: UInt16, token: String) { self.port = port; self.token = token }
    public func validate(_ request: HTTPRequest) throws {
        let locals = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"], locals.contains(host.lowercased()) else { throw HTTPFailure(403) }
        if let origin = request.headers["origin"], !locals.map({ "http://" + $0 }).contains(origin.lowercased()) {
            throw HTTPFailure(403)
        }
        guard ConstantTime.equal(request.headers["authorization"] ?? "", "Bearer " + token) else { throw HTTPFailure(401) }
        guard request.method == "POST" else { throw HTTPFailure(405) }
        guard request.target == "/mcp" else { throw HTTPFailure(404) }
        let contentType = request.headers["content-type"]?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
        guard contentType == "application/json" else { throw HTTPFailure(415) }
        let accepts = (request.headers["accept"] ?? "").lowercased().split(separator: ",").map {
            $0.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        guard accepts.contains("application/json") || accepts.contains("*/*") else { throw HTTPFailure(406) }
        if let version = request.headers["mcp-protocol-version"], !MCPDispatcher.versions.contains(version) { throw HTTPFailure(400) }
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: fragmentación byte a byte, límites, smuggling y rebinding pasan. Revisar manualmente el bucle de comparación: 71 iteraciones para Bearer+token, incluso si falta o falla el primer byte; no sustituirlo por `==` ni comparar hashes con salida temprana.

- [ ] **Step 5: Commit** (Claude): `feat: parser HTTP limitado y autenticación local MCP`

---

### Task 7: NWListener loopback, lectura acotada y pruebas con URLSession

**Files:**
- Create: `Sources/GimbalKitMCP/HTTPServer.swift`
- Test: `Tests/GimbalKitMCPTests/HTTPServerTests.swift`

**Interfaces:**
- Consumes: Task 6 `HTTPParser.feed(_:)` y `HTTPGate.validate(_:)`; Task 5 `MCPDispatcher.respond(to:)`; Task 1 `RuntimeClock.sleep`.
- Produces: `@MainActor protocol MCPServerControl: AnyObject, Sendable { func start(port: UInt16) async throws -> UInt16; func stop() async }`; `@MainActor final class HTTPServer: MCPServerControl { init(service: any GimbalService, token: String, clock: RuntimeClock = .live); start(port: UInt16 = 0) async throws -> UInt16; stop() async }`. Máximo 16 peers; plazo total de lectura 5 s desde aceptación; una respuesta y cierre.

- [ ] **Step 1: Escribir las pruebas que fallan**

`Tests/GimbalKitMCPTests/HTTPServerTests.swift`:
```swift
import Foundation
import Network
import Testing
import GimbalKit
@testable import GimbalKitMCP

func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 3
    configuration.connectionProxyDictionary = [:]
    return URLSession(configuration: configuration)
}
func post(port: UInt16, token: String = testToken, origin: String? = nil,
          body: String = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) -> URLRequest {
    var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    r.httpMethod = "POST"; r.httpBody = Data(body.utf8)
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    if let origin { r.setValue(origin, forHTTPHeaderField: "Origin") }
    return r
}

@MainActor @Test func httpLoopbackUsesEphemeralPortAndChecksCredentialsAndOrigin() async throws {
    let server = HTTPServer(service: FakeService(), token: testToken)
    let port = try await server.start(port: 0)
    #expect(port > 0)
    let client = session()
    do {
        for (request, expected) in [(post(port: port), 200), (post(port: port, token: "bad"), 401),
                                     (post(port: port, origin: "http://evil.test"), 403),
                                     (post(port: port, body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), 202)] {
            let (_, response) = try await client.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == expected)
        }
        var nonBound = post(port: port)
        nonBound.url = URL(string: "http://127.0.0.2:\(port)/mcp")!
        await #expect(throws: URLError.self) { try await client.data(for: nonBound) }
    } catch { await server.stop(); client.invalidateAndCancel(); throw error }
    await server.stop(); client.invalidateAndCancel()
}

actor ReadDeadline {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private(set) var waiting = false
    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }
    func sleep() async throws {
        waiting = true
        for await _ in stream { break }
        try Task.checkCancellation()
    }
    func fire() { continuation.yield(()) }
}

@MainActor @Test func incompleteHTTPRequestTimesOutWithoutRealSleep() async throws {
    let gate = ReadDeadline()
    let server = HTTPServer(service: FakeService(), token: testToken,
                            clock: RuntimeClock(now: { Date() }, sleep: { _ in try await gate.sleep() }))
    let port = try await server.start(port: 0)
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.start(queue: DispatchQueue(label: "gimbal.test.raw"))
    let response = Task { () throws -> Data in
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data("POST /mcp HTTP/1.1\r\nHost: ".utf8), completion: .contentProcessed { @Sendable error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
        var buffer = Data()
        while buffer.count < 4096 {
            let part: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096 - buffer.count) { @Sendable data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
            if part.isEmpty { return buffer }
            buffer.append(part)
            if buffer.range(of: Data([13, 10])) != nil { return buffer }
        }
        throw HTTPFailure(431)
    }
    while !(await gate.waiting) { await Task.yield() }
    await gate.fire()
    do { #expect(String(decoding: try await response.value, as: UTF8.self).hasPrefix("HTTP/1.1 408")) }
    catch { connection.cancel(); await server.stop(); throw error }
    connection.cancel(); await server.stop()
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter 'httpLoopback|incompleteHTTP'`
Expected: no existe `HTTPServer`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKitMCP/HTTPServer.swift`:
```swift
import Foundation
import Network
import GimbalKit

@MainActor public protocol MCPServerControl: AnyObject, Sendable {
    func start(port: UInt16) async throws -> UInt16
    func stop() async
}
@MainActor public final class HTTPServer: MCPServerControl {
    private let dispatcher: MCPDispatcher
    private let token: String
    private let clock: RuntimeClock
    private let queue = DispatchQueue(label: "gimbalkit.http")
    private var listener: NWListener?
    private var readiness: CheckedContinuation<UInt16, any Error>?
    private var generation = UUID()
    private var peers: [UUID: HTTPPeer] = [:]
    public init(service: any GimbalService, token: String, clock: RuntimeClock = .live) {
        dispatcher = MCPDispatcher(service: service); self.token = token; self.clock = clock
    }
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        guard listener == nil else { throw HTTPFailure(409) }
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let created = try NWListener(using: parameters)
        listener = created
        let current = UUID(); generation = current
        created.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                switch state {
                case .ready:
                    guard let actual = created.port?.rawValue else { self.finish(.failure(HTTPFailure(500))); return }
                    self.finish(.success(actual))
                case let .failed(error): self.finish(.failure(error)); await self.stop()
                case .cancelled: self.finish(.failure(CancellationError()))
                default: break
                }
            }
        }
        created.newConnectionHandler = { @Sendable [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == current, let port = created.port?.rawValue,
                      self.peers.count < 16 else { connection.cancel(); return }
                let id = UUID()
                let peer = HTTPPeer(connection: connection, gate: HTTPGate(port: port, token: self.token),
                                    dispatcher: self.dispatcher, clock: self.clock, onClose: { [weak self] in self?.peers[id] = nil })
                self.peers[id] = peer
                peer.start(queue: self.queue)
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readiness = continuation
                created.start(queue: queue)
            }
        } onCancel: { Task { @MainActor [weak self] in await self?.stop() } }
    }
    private func finish(_ result: Result<UInt16, any Error>) {
        let continuation = readiness; readiness = nil
        continuation?.resume(with: result)
    }
    public func stop() async {
        generation = UUID()
        finish(.failure(CancellationError()))
        listener?.cancel(); listener = nil
        let current = Array(peers.values)
        let work = current.compactMap(\.work)
        for peer in current { peer.close() }
        peers.removeAll()
        for task in work { await task.value }
    }
}

@MainActor private final class HTTPPeer {
    private let connection: NWConnection
    private let gate: HTTPGate
    private let dispatcher: MCPDispatcher
    private let clock: RuntimeClock
    private let onClose: @MainActor () -> Void
    private var parser = HTTPParser()
    private var deadline: Task<Void, Never>?
    private(set) var work: Task<Void, Never>?
    private var closed = false
    private var responding = false
    init(connection: NWConnection, gate: HTTPGate, dispatcher: MCPDispatcher,
         clock: RuntimeClock, onClose: @escaping @MainActor () -> Void) {
        self.connection = connection; self.gate = gate; self.dispatcher = dispatcher
        self.clock = clock; self.onClose = onClose
    }
    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: queue)
        deadline = Task { [weak self] in
            guard let self else { return }
            do { try await clock.sleep(5); if !Task.isCancelled { send(RPCReply(status: 408, body: Data())) } }
            catch { return }
        }
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { @Sendable [weak self] data, _, complete, error in
            Task { @MainActor in self?.received(data: data, complete: complete, failed: error != nil) }
        }
    }
    private func received(data: Data?, complete: Bool, failed: Bool) {
        guard !closed, !responding else { return }
        if failed { close(); return }
        do {
            if let request = try parser.feed(data ?? Data()) {
                deadline?.cancel(); deadline = nil
                try gate.validate(request)
                // En este transporte un EOF cancela la operación; no admitir half-close con movimiento.
                guard !complete else { close(); return }
                work = Task { [weak self] in
                    guard let self else { return }
                    let reply = await dispatcher.respond(to: request.body)
                    guard !Task.isCancelled, !closed else { return }
                    work = nil
                    send(reply)
                }
                watchDisconnect()
            } else if complete { send(RPCReply(status: 400, body: Data())) }
            else { receive() }
        } catch let error as HTTPFailure { send(RPCReply(status: error.status, body: Data())) }
        catch { send(RPCReply(status: 400, body: Data())) }
    }
    private func watchDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { @Sendable [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.responding else { return }
                if complete || error != nil || !(data?.isEmpty ?? true) { self.close() }
                else { self.watchDisconnect() }
            }
        }
    }
    private func send(_ reply: RPCReply) {
        guard !closed, !responding else { return }
        responding = true; deadline?.cancel(); deadline = nil
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                       404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout",
                       411: "Length Required", 413: "Content Too Large", 415: "Unsupported Media Type", 431: "Request Header Fields Too Large"]
        var text = "HTTP/1.1 \(reply.status) \(reasons[reply.status] ?? "Error")\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n"
        if !reply.body.isEmpty { text += "Content-Type: application/json\r\n" }
        if reply.status == 401 { text += "WWW-Authenticate: Bearer\r\n" }
        if reply.status == 405 { text += "Allow: POST\r\n" }
        // Sin Access-Control-Allow-Origin: no habilitar CORS para páginas web.
        text += "\r\n"
        connection.send(content: Data(text.utf8) + reply.body, completion: .contentProcessed { @Sendable [weak self] _ in
            Task { @MainActor in self?.close() }
        })
    }
    func close() {
        guard !closed else { return }
        closed = true; deadline?.cancel(); work?.cancel()
        deadline = nil; connection.cancel(); onClose()
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: URLSession obtiene JSON 200, notificación 202, 401/403; `127.0.0.2` no conecta; lectura incompleta da 408 con señal manual. No se hacen conexiones a internet. `stop()` cancela y espera las herramientas en curso, incluyendo cleanup del navegador.

- [ ] **Step 5: Commit** (Claude): `feat: servidor MCP HTTP en loopback con lectura acotada`

---

### Task 8: Runtime del anfitrión, servicio real y reconexión sin UI

**Files:**
- Create: `Sources/GimbalHostSupport/HostRuntime.swift`
- Modify: `Package.swift`, `Sources/GimbalKitBLE/CoreBluetoothOMTransport.swift`
- Test: `Tests/GimbalHostSupportTests/HostRuntimeTests.swift`

**Interfaces:**
- Consumes: Task 5 `GimbalService`; `OMDevice.init(transport:now:)`, `start()/shutdown()/poseSample()/battery`; Tasks 2–4 controlador, navegador y store.
- Produces: `protocol HostLink: OMTransport { var disconnects: AsyncStream<Void> { get }; func connect() async throws; func disconnect() async }`; `HostRuntime.init(makeLink: @escaping @Sendable () -> any HostLink, store: ZoneStore, clock: RuntimeClock = .live)`, `start() async throws`, `shutdown() async`, `tickOnce() async`, `auditEntries() async -> [AuditEntry]`, métodos de `GimbalService`, `humanStop() async`, `prepareZone(name: String, forbidden: Bool = false) async throws -> ZoneDraft`, `confirmZone(_ draft: ZoneDraft) async throws`, `prepareReference() async throws -> ReferenceDraft`, `confirmReference(_ draft: ReferenceDraft) async throws`. Los drafts contienen UUID de sesión y confirmación y pose capturada; no hay esos métodos en MCP. El booleano «zona prohibida» existe únicamente en el formulario humano.

- [ ] **Step 1: Escribir las pruebas que fallan y ampliar el manifiesto**

`Package.swift`:
```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "GimbalKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GimbalKit", targets: ["GimbalKit"]),
        .library(name: "GimbalKitSim", targets: ["GimbalKitSim"]),
        .library(name: "GimbalKitDJI", targets: ["GimbalKitDJI"]),
        .library(name: "GimbalKitBLE", targets: ["GimbalKitBLE"]),
        .library(name: "GimbalKitMCP", targets: ["GimbalKitMCP"]),
        .library(name: "GimbalHostSupport", targets: ["GimbalHostSupport"]),
    ],
    targets: [
        .target(name: "GimbalKit"),
        .target(name: "GimbalKitSim", dependencies: ["GimbalKit"]),
        .target(name: "GimbalKitDJI", dependencies: ["GimbalKit"]),
        .target(name: "GimbalKitBLE", dependencies: ["GimbalKitDJI"]),
        .target(name: "GimbalKitMCP", dependencies: ["GimbalKit"]),
        .target(name: "GimbalHostSupport", dependencies: ["GimbalKit", "GimbalKitDJI", "GimbalKitMCP"]),
        .executableTarget(name: "GimbalSmoke", dependencies: ["GimbalKitBLE", "GimbalKitDJI", "GimbalKit"]),
        .testTarget(name: "GimbalKitTests", dependencies: ["GimbalKit", "GimbalKitSim"]),
        .testTarget(name: "GimbalKitDJITests", dependencies: ["GimbalKitDJI", "GimbalKit"]),
        .testTarget(name: "GimbalKitMCPTests", dependencies: ["GimbalKitMCP", "GimbalKit"]),
        .testTarget(name: "GimbalHostSupportTests", dependencies: ["GimbalHostSupport", "GimbalKit", "GimbalKitDJI", "GimbalKitMCP", "GimbalKitSim"]),
    ]
)
```

`Tests/GimbalHostSupportTests/HostRuntimeTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit
import GimbalKitDJI
import GimbalKitMCP
import GimbalKitSim
@testable import GimbalHostSupport

enum TestLinkError: Error { case failed }
actor FakeLink: HostLink {
    nonisolated let notifications: AsyncStream<[UInt8]>
    nonisolated let disconnects: AsyncStream<Void>
    private let bytes: AsyncStream<[UInt8]>.Continuation
    private let disconnected: AsyncStream<Void>.Continuation
    private let fails: Bool
    private(set) var writes: [[UInt8]] = []
    private(set) var closed = false
    init(fails: Bool = false) {
        self.fails = fails
        (notifications, bytes) = AsyncStream.makeStream(of: [UInt8].self)
        (disconnects, disconnected) = AsyncStream.makeStream(of: Void.self)
    }
    func connect() throws { if fails { throw TestLinkError.failed } }
    func disconnect() { closed = true; disconnected.finish(); bytes.finish() }
    func write(_ data: [UInt8]) { writes.append(data) }
    func drop() { disconnected.yield(()) }
    func attitude() {
        let hex = "553e044b04026e7c00040501f9fcff000084000300200132c503002c1800000c005403e36ab83eb4debbbea1fe193f98821cbf000000000100000000f6bc"
        let raw = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        bytes.yield(raw)
    }
}
final class LinkFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var links: [any HostLink]
    private var count = 0
    init(_ links: [any HostLink]) { self.links = links }
    func next() -> any HostLink { lock.withLock { count += 1; return links.removeFirst() } }
    var attempts: Int { lock.withLock { count } }
}
actor StepSleeper {
    let clock = ManualClock()
    private var continuations: [AsyncStream<Void>.Continuation] = []
    private(set) var requested: [Double] = []
    nonisolated func now() -> Date { clock.now() }
    func sleep(_ seconds: Double) async throws {
        requested.append(seconds)
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        continuations.append(continuation)
        for await _ in stream { break }
        try Task.checkCancellation()
    }
    func advance(_ seconds: Double) {
        clock.advance(seconds)
        let pending = continuations; continuations.removeAll()
        for continuation in pending { continuation.yield(()); continuation.finish() }
    }
}
func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<10000 { if await condition() { return true }; await Task.yield() }
    return false
}

@Test func hostBackoffReferenceConfirmationPersistenceAndDisconnect() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let failed = FakeLink(fails: true), good = FakeLink(), next = FakeLink()
    let factory = LinkFactory([failed, good, next])
    let sleeper = StepSleeper()
    let timing = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let store = ZoneStore(url: root.appendingPathComponent("zones.json"))
    let runtime = HostRuntime(makeLink: { factory.next() }, store: store, clock: timing)
    try await runtime.start()
    #expect(await eventually { await sleeper.requested.contains(0.5) })
    #expect(factory.attempts == 1)
    await sleeper.advance(0.5)
    #expect(await eventually { (try? await runtime.status().connected) == true })
    await good.attitude()
    #expect(await eventually { (try? await runtime.status().pose) != nil })
    let draft = try await runtime.prepareZone(name: "mesa")
    #expect(try await store.load().isEmpty)
    try await runtime.confirmZone(draft)
    #expect(try await store.load().first?.name == "mesa")
    #expect(try await runtime.status().referenceReady)
    await good.drop()
    #expect(await eventually { (try? await runtime.status().connected) == false })
    #expect(await eventually { await sleeper.requested.filter { $0 == 0.5 }.count == 2 })
    await sleeper.advance(0.5)
    #expect(await eventually {
        let connected = (try? await runtime.status().connected) == true
        return factory.attempts == 3 && connected
    })
    await next.attitude()
    #expect(await eventually { (try? await runtime.status().pose) != nil })
    #expect(try await runtime.status().referenceReady == false)
    await #expect(throws: NavigationError.referenceRequired) { try await runtime.look(zone: "mesa", leaseSeconds: 30) }
    let reference = try await runtime.prepareReference()
    try await runtime.confirmReference(reference)
    #expect(try await runtime.status().referenceReady)
    await runtime.humanStop()
    #expect(await runtime.auditEntries().contains { $0.source == .app && $0.event == "stop" })
    await runtime.shutdown()
    #expect(await next.closed)
    #expect(factory.attempts == 3)
}

@Test func backoffIsBounded() {
    #expect((0..<8).map(HostRuntime.backoff) == [0.5, 1, 2, 4, 8, 8, 8, 8])
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: `HostRuntime` y `HostLink` inexistentes/target todavía vacío.

- [ ] **Step 3: Implementar**

`Sources/GimbalHostSupport/HostRuntime.swift`:
```swift
import Foundation
import GimbalKit
import GimbalKitDJI
import GimbalKitMCP

public protocol HostLink: OMTransport {
    var disconnects: AsyncStream<Void> { get }
    func connect() async throws
    func disconnect() async
}
public struct ZoneDraft: Sendable {
    public let id: UUID
    public let session: UUID
    public let zone: Zone
    public let pose: Pose
}
public struct ReferenceDraft: Sendable {
    public let id: UUID
    public let session: UUID
    public let pose: Pose
}
public actor HostRuntime: GimbalService {
    private struct Rig {
        let id: UUID
        let link: any HostLink
        let device: OMDevice
        let controller: GimbalController
        let navigator: GotoNavigator
    }
    private let makeLink: @Sendable () -> any HostLink
    private let store: ZoneStore
    private let clock: RuntimeClock
    private let audit = AuditLog()
    private var savedZones: [Zone] = []
    private var rig: Rig?
    private var referenceReady = false
    private var pendingZone: ZoneDraft?
    private var pendingReference: ReferenceDraft?
    private var connecting: (UUID, any HostLink)?
    private var loop: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var generation = UUID()
    private var started = false
    private var looking = false
    private var editing = false

    public init(makeLink: @escaping @Sendable () -> any HostLink, store: ZoneStore, clock: RuntimeClock = .live) {
        self.makeLink = makeLink; self.store = store; self.clock = clock
    }
    public static func backoff(_ failure: Int) -> Double { min(8, 0.5 * pow(2, Double(min(4, max(0, failure))))) }
    public func start() async throws {
        guard !started else { return }
        started = true
        let current = UUID(); generation = current
        let loaded: [Zone]
        do { loaded = try await store.load() }
        catch { if generation == current { started = false }; throw error }
        guard started, generation == current else { return }
        savedZones = loaded
        ticker = Task { [weak self, clock] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tickOnce()
                do { try await clock.sleep(0.1) } catch { break }
            }
        }
        loop = Task { [weak self] in await self?.connectLoop(generation: current) }
    }
    private func connectLoop(generation current: UUID) async {
        var failures = 0
        while !Task.isCancelled, started, generation == current {
            let link = makeLink()
            let id = UUID()
            connecting = (id, link)
            do {
                try await link.connect()
                try Task.checkCancellation()
                guard started, generation == current else { throw CancellationError() }
                connecting = nil
                let device = OMDevice(transport: link, now: clock.now)
                let policy = SafetyPolicy(maxSpeed: 6, maxLeaseSeconds: 30, deadmanSeconds: 0.5, zones: [])
                let controller = GimbalController(device: device, policy: policy, now: clock.now, audit: audit)
                let active = Rig(id: id, link: link, device: device, controller: controller,
                                 navigator: GotoNavigator(controller: controller, clock: clock))
                rig = active; referenceReady = false; pendingZone = nil; pendingReference = nil
                await device.start()
                await log("connected; reference confirmation required")
                failures = 0
                for await _ in link.disconnects { break }
                if rig?.id == id {
                    rig = nil; referenceReady = false; pendingZone = nil; pendingReference = nil
                    await controller.deviceDisconnected()
                }
                await device.shutdown()
            } catch {
                if connecting?.0 == id { connecting = nil }
                await log(error is CancellationError ? "connection cancelled" : "connection failed")
            }
            await link.disconnect()
            guard !Task.isCancelled, started, generation == current else { break }
            do { try await clock.sleep(Self.backoff(failures)) } catch { break }
            failures += 1
        }
    }
    public func shutdown() async {
        started = false; generation = UUID()
        let oldLoop = loop, oldTicker = ticker
        loop = nil; ticker = nil; oldLoop?.cancel(); oldTicker?.cancel()
        let old = rig; rig = nil; referenceReady = false; pendingZone = nil; pendingReference = nil
        if let old { await old.controller.stop(source: .app); await old.device.shutdown(); await old.link.disconnect() }
        if let pending = connecting { connecting = nil; await pending.1.disconnect() }
        await oldLoop?.value; await oldTicker?.value
    }
    public func tickOnce() async { if let rig { await rig.controller.tick() } }
    public func auditEntries() async -> [AuditEntry] { await audit.entries() }
    public func status() async throws -> GimbalStatus {
        guard let captured = rig else { return GimbalStatus(connected: false, referenceReady: false, battery: nil, pose: nil, lease: nil) }
        let sample = await captured.device.poseSample()
        let battery = await captured.device.battery
        let lease = await captured.controller.activeLease
        guard rig?.id == captured.id else { return GimbalStatus(connected: false, referenceReady: false, battery: nil, pose: nil, lease: nil) }
        let fresh = sample.flatMap { sample -> Pose? in
            let age = clock.now().timeIntervalSince(sample.receivedAt)
            return age >= 0 && age <= 1.5 ? sample.pose : nil
        }
        return GimbalStatus(connected: true, referenceReady: referenceReady,
                            battery: battery.map { BatteryStatus(percent: $0.percent, charging: $0.charging) }, pose: fresh,
                            lease: lease.map { LeaseStatus(zone: $0.zone, expiresAt: $0.expiresAt) })
    }
    public func zones() -> [ZoneRecord] { savedZones.map(ZoneRecord.init) }
    public func look(zone: String, leaseSeconds: Double) async throws -> Pose {
        guard let captured = rig else { throw SafetyViolation.poseUnavailable }
        guard referenceReady else { throw NavigationError.referenceRequired }
        guard leaseSeconds.isFinite, leaseSeconds > 0, leaseSeconds <= 30 else { throw SafetyViolation.invalidDuration }
        guard !looking, !editing else { throw NavigationError.busy }
        looking = true
        defer { looking = false }
        if let existing = await captured.controller.activeLease { throw SafetyViolation.busy(holder: existing.source) }
        guard rig?.id == captured.id, referenceReady else { throw NavigationError.interrupted }
        let lease = try await captured.controller.requestLease(source: .agent("mcp"), zone: zone, seconds: leaseSeconds)
        do { return try await captured.navigator.go(to: zone, source: .agent("mcp"), lease: lease) }
        catch { await captured.controller.release(lease: lease); throw error }
    }
    public func stop() async throws { if let rig { await rig.controller.stop(source: .agent("mcp")) } }
    public func humanStop() async { if let rig { await rig.controller.stop(source: .app) } }
    private func freshRig() async throws -> (Rig, Pose) {
        guard let captured = rig, let sample = await captured.device.poseSample(), sample.pose.isFinite else {
            throw SafetyViolation.poseUnavailable
        }
        guard rig?.id == captured.id else { throw NavigationError.interrupted }
        let age = clock.now().timeIntervalSince(sample.receivedAt)
        guard age >= 0, age <= 1.5 else { throw NavigationError.stalePose }
        return (captured, sample.pose)
    }
    public func prepareZone(name: String, forbidden: Bool = false) async throws -> ZoneDraft {
        let (captured, pose) = try await freshRig()
        guard !looking, !editing, referenceReady || savedZones.isEmpty else { throw NavigationError.referenceRequired }
        let zone = Zone(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        yaw: (pose.yaw - 10)...(pose.yaw + 10), pitch: (pose.pitch - 10)...(pose.pitch + 10), forbidden: forbidden)
        _ = try ZoneRecord(zone).zone()
        guard !savedZones.contains(where: { $0.name == zone.name }) else { throw ZoneStoreError.invalidZone }
        let draft = ZoneDraft(id: UUID(), session: captured.id, zone: zone, pose: pose)
        pendingZone = draft
        return draft
    }
    public func confirmZone(_ draft: ZoneDraft) async throws {
        let (captured, pose) = try await freshRig()
        guard pendingZone?.id == draft.id, captured.id == draft.session, !looking, !editing,
              abs(pose.yaw - draft.pose.yaw) <= 2, abs(pose.pitch - draft.pose.pitch) <= 2 else { throw NavigationError.interrupted }
        editing = true
        defer { editing = false }
        pendingZone = nil
        let updated = savedZones + [draft.zone]
        try await store.save(updated)
        savedZones = updated
        guard rig?.id == captured.id else { throw NavigationError.interrupted }
        referenceReady = true
        await captured.controller.replaceZones(updated)
        await log("zone saved: \(draft.zone.name)")
    }
    public func prepareReference() async throws -> ReferenceDraft {
        let (captured, pose) = try await freshRig()
        guard !looking, !editing else { throw NavigationError.busy }
        let draft = ReferenceDraft(id: UUID(), session: captured.id, pose: pose)
        pendingReference = draft
        return draft
    }
    public func confirmReference(_ draft: ReferenceDraft) async throws {
        let (captured, pose) = try await freshRig()
        guard pendingReference?.id == draft.id, captured.id == draft.session, !looking, !editing,
              abs(pose.yaw - draft.pose.yaw) <= 2, abs(pose.pitch - draft.pose.pitch) <= 2 else { throw NavigationError.interrupted }
        editing = true
        defer { editing = false }
        pendingReference = nil
        await captured.controller.replaceZones(savedZones)
        guard rig?.id == captured.id else { throw NavigationError.interrupted }
        referenceReady = true
        await log("reference confirmed by human")
    }
    private func log(_ event: String) async {
        await audit.record(AuditEntry(date: clock.now(), source: .app, event: event, outcome: .accepted))
    }
}
```

En `Sources/GimbalKitBLE/CoreBluetoothOMTransport.swift`, sustituir la propiedad pública `onDisconnect` por este bloque dentro de la clase (todos los accesos al callback usan el mismo lock):
```swift
    private let callbackLock = NSLock()
    private var disconnectCallback: (@Sendable () -> Void)?
    public var onDisconnect: (@Sendable () -> Void)? {
        get { callbackLock.withLock { disconnectCallback } }
        set { callbackLock.withLock { disconnectCallback = newValue } }
    }
    private var connectionTicket: UUID?
```

Añadir este tipo privado a nivel de fichero, después de los imports:
```swift
private final class ConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}
```

Sustituir completamente `connect(timeout:)`, `disconnect()` y `finishConnection(_:)` por:
```swift
    public func connect(timeout: TimeInterval = 15) async throws {
        try Task.checkCancellation()
        let ticket = UUID()
        let cancellation = ConnectionCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard !cancellation.isCancelled else { cont.resume(throwing: CancellationError()); return }
                    guard self.connection == nil else { cont.resume(throwing: BLEError.discoveryFailed); return }
                    self.connectionTicket = ticket
                    self.connection = cont
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        guard self.connectionTicket == ticket else { return }
                        self.central.stopScan()
                        self.finishConnection(.failure(BLEError.timedOut))
                    }
                    self.beginIfPoweredOn()
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.queue.async {
                guard self.connectionTicket == ticket else { return }
                self.central.stopScan()
                if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
                self.finishConnection(.failure(CancellationError()))
            }
        }
    }
    public func disconnect() {
        queue.async {
            self.central.stopScan()
            self.finishConnection(.failure(CancellationError()))
            self.notifyCharacteristic = nil; self.writeCharacteristic = nil
            if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
        }
    }
    private func finishConnection(_ result: Result<Void, Error>) {
        guard let cont = connection else { return }
        connection = nil; connectionTicket = nil
        cont.resume(with: result)
    }
```

No modificar la serialización de `write(_:)` del driver: sigue en su cola serial. El runtime crea un transporte nuevo por intento, por lo que callbacks tardíos de un periférico/timeout anterior no pueden completar el intento siguiente.

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: reconexión/backoff, persistencia solo tras confirmación, referencia invalidada y cierre pasan sin instanciar CoreBluetooth. El adapter real modificado compila; el permiso y la cancelación real de BLE se verifican en Task 11.

- [ ] **Step 5: Commit** (Claude): `feat: runtime macOS con reconexión y confirmación humana de zonas`

---

### Task 9: Cliente MCP y CLI gimbal sin Bluetooth

**Files:**
- Create: `Sources/GimbalKitMCP/MCPClient.swift`, `Sources/GimbalCLI/GimbalCLI.swift`
- Modify: `Package.swift` (sustituir manifiesto)
- Test: `Tests/GimbalKitMCPTests/ClientTests.swift`

**Interfaces:**
- Consumes: `LocalFiles.token(create: false) -> String`, `readEndpoint() -> UInt16`, `JSONValue` y Task 7 HTTP.
- Produces: `MCPClient.init(port: UInt16, token: String, session: URLSession = .shared)`, `tool(_ name: String, arguments: [String: JSONValue] = [:]) async throws -> JSONValue`; `CLICommand.init(arguments: [String]) throws`, `run(client: MCPClient) async throws -> JSONValue`; ejecutable `gimbal status|zones|look <zona>|stop`. El cliente negocia initialize/initialized; endpoint.json contiene el puerto real, no un puerto fijo supuesto.

- [ ] **Step 1: Escribir las pruebas que fallan y el manifiesto**

`Package.swift`:
```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "GimbalKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GimbalKit", targets: ["GimbalKit"]),
        .library(name: "GimbalKitSim", targets: ["GimbalKitSim"]),
        .library(name: "GimbalKitDJI", targets: ["GimbalKitDJI"]),
        .library(name: "GimbalKitBLE", targets: ["GimbalKitBLE"]),
        .library(name: "GimbalKitMCP", targets: ["GimbalKitMCP"]),
        .library(name: "GimbalHostSupport", targets: ["GimbalHostSupport"]),
        .executable(name: "gimbal", targets: ["GimbalCLI"]),
    ],
    targets: [
        .target(name: "GimbalKit"),
        .target(name: "GimbalKitSim", dependencies: ["GimbalKit"]),
        .target(name: "GimbalKitDJI", dependencies: ["GimbalKit"]),
        .target(name: "GimbalKitBLE", dependencies: ["GimbalKitDJI"]),
        .target(name: "GimbalKitMCP", dependencies: ["GimbalKit"]),
        .target(name: "GimbalHostSupport", dependencies: ["GimbalKit", "GimbalKitDJI", "GimbalKitMCP"]),
        .executableTarget(name: "GimbalCLI", dependencies: ["GimbalKitMCP"]),
        .executableTarget(name: "GimbalSmoke", dependencies: ["GimbalKitBLE", "GimbalKitDJI", "GimbalKit"]),
        .testTarget(name: "GimbalKitTests", dependencies: ["GimbalKit", "GimbalKitSim"]),
        .testTarget(name: "GimbalKitDJITests", dependencies: ["GimbalKitDJI", "GimbalKit"]),
        .testTarget(name: "GimbalKitMCPTests", dependencies: ["GimbalKitMCP", "GimbalKit"]),
        .testTarget(name: "GimbalHostSupportTests", dependencies: ["GimbalHostSupport", "GimbalKit", "GimbalKitDJI", "GimbalKitMCP", "GimbalKitSim"]),
    ]
)
```

`Tests/GimbalKitMCPTests/ClientTests.swift`:
```swift
import Foundation
import Testing
@testable import GimbalKitMCP

@MainActor @Test func cliCommandsUseMCPAndBadCredentialsFail() async throws {
    let fake = FakeService()
    let server = HTTPServer(service: fake, token: testToken)
    let port = try await server.start(port: 0)
    let urlSession = session()
    let client = MCPClient(port: port, token: testToken, session: urlSession)
    do {
        let status = try await CLICommand(arguments: ["status"]).run(client: client)
        #expect(status["connected"] == .bool(true))
        #expect(try await CLICommand(arguments: ["zones"]).run(client: client)["zones"].array?.count == 1)
        _ = try await CLICommand(arguments: ["look", "mesa"]).run(client: client)
        _ = try await CLICommand(arguments: ["stop"]).run(client: client)
        let looks = await fake.looks.count
        let stops = await fake.stops
        #expect(looks == 1 && stops == 1)
        let bad = MCPClient(port: port, token: "wrong", session: urlSession)
        await #expect(throws: CLIError.http(401)) { try await bad.tool("gimbal_status") }
        await #expect(throws: CLIError.tool("unsafePath")) { try await client.tool("gimbal_look", arguments: ["zone": .string("fallo")]) }
        for args in [[], ["look"], ["look", "mesa", "extra"], ["create", "mesa"], ["status", "--source=app"]] {
            #expect(throws: CLIError.usage) { try CLICommand(arguments: args) }
        }
    } catch { urlSession.invalidateAndCancel(); await server.stop(); throw error }
    urlSession.invalidateAndCancel(); await server.stop()
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter cliCommandsUseMCPAndBadCredentialsFail`
Expected: símbolos nuevos inexistentes/target CLI todavía vacío.

- [ ] **Step 3: Implementar**

`Sources/GimbalKitMCP/MCPClient.swift`:
```swift
import Foundation

public enum CLIError: Error, Sendable, Equatable {
    case usage, http(Int), invalidResponse, rpc(Int), tool(String)
    public var message: String {
        switch self {
        case .usage: "Uso: gimbal status | zones | look <zona> | stop"
        case let .http(code): "El servidor respondió HTTP \(code)."
        case .invalidResponse: "Respuesta MCP inválida."
        case let .rpc(code): "Error JSON-RPC \(code)."
        case let .tool(code): "La herramienta falló: \(code)."
        }
    }
}
public struct MCPClient: Sendable {
    private let port: UInt16
    private let token: String
    private let session: URLSession
    public init(port: UInt16, token: String, session: URLSession = .shared) {
        self.port = port; self.token = token; self.session = session
    }
    public func tool(_ name: String, arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let initialized = try await request(method: "initialize", params: .object([
            "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("gimbal"), "version": .string("1.0")])]))
        guard let version = initialized["protocolVersion"].string, MCPDispatcher.versions.contains(version) else { throw CLIError.invalidResponse }
        _ = try await post(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]), version: version, notification: true)
        let result = try await request(method: "tools/call", params: .object(["name": .string(name), "arguments": .object(arguments)]), version: version)
        if result["isError"] == .bool(true) { throw CLIError.tool(result["structuredContent"]["error"].string ?? "deviceUnavailable") }
        guard result["isError"] == .bool(false), result.object?["structuredContent"] != nil else { throw CLIError.invalidResponse }
        return result["structuredContent"]
    }
    private func request(method: String, params: JSONValue, version: String? = nil) async throws -> JSONValue {
        let reply = try await post(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method), "params": params]), version: version)
        guard reply["jsonrpc"] == .string("2.0"), reply["id"] == .number(1) else { throw CLIError.invalidResponse }
        if let code = reply["error"]["code"].number, code.isFinite, (-32768...0).contains(code) { throw CLIError.rpc(Int(code)) }
        guard reply.object?["result"] != nil else { throw CLIError.invalidResponse }
        return reply["result"]
    }
    private func post(_ value: JSONValue, version: String?, notification: Bool = false) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(value)
        request.timeoutInterval = 35
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CLIError.invalidResponse }
        guard http.statusCode == (notification ? 202 : 200) else { throw CLIError.http(http.statusCode) }
        if notification { guard data.isEmpty else { throw CLIError.invalidResponse }; return .null }
        guard data.count <= 1_048_576 else { throw CLIError.invalidResponse }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
public enum CLICommand: Sendable {
    case status, zones, look(String), stop
    public init(arguments: [String]) throws {
        switch arguments {
        case ["status"]: self = .status
        case ["zones"]: self = .zones
        case ["stop"]: self = .stop
        case let args where args.count == 2 && args[0] == "look" && !args[1].isEmpty: self = .look(args[1])
        default: throw CLIError.usage
        }
    }
    public func run(client: MCPClient) async throws -> JSONValue {
        switch self {
        case .status: try await client.tool("gimbal_status")
        case .zones: try await client.tool("gimbal_zones")
        case let .look(zone): try await client.tool("gimbal_look", arguments: ["zone": .string(zone), "lease_seconds": .number(30)])
        case .stop: try await client.tool("gimbal_stop")
        }
    }
}
```

`Sources/GimbalCLI/GimbalCLI.swift`:
```swift
import Foundation
import Darwin
import GimbalKitMCP

@main struct GimbalCLI {
    static func main() async {
        do {
            let command = try CLICommand(arguments: Array(CommandLine.arguments.dropFirst()))
            let files = try LocalFiles()
            let token = try files.token(create: false)
            let port = try files.readEndpoint()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 35
            configuration.timeoutIntervalForResource = 40
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let result = try await command.run(client: MCPClient(port: port, token: token, session: session))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        } catch {
            let message = (error as? CLIError)?.message ?? "No se pudo contactar con GimbalHostMac. Abra la app y active MCP."
            FileHandle.standardError.write(Data(("gimbal: " + message + "\n").utf8))
            exit(1)
        }
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift build --disable-sandbox --scratch-path .build --product gimbal`
Expected: cuatro comandos probados contra puerto efímero, 401 y error de herramienta visibles, argumentos inválidos rechazados; la CLI no importa `GimbalKitBLE` ni crea tokens. No lanzar la app.

- [ ] **Step 5: Commit** (Claude): `feat: cliente MCP local y CLI gimbal`

---

### Task 10: Modelo probado, MenuBarExtra y empaquetado sin lanzar Bluetooth

**Files:**
- Create: `Sources/GimbalHostSupport/HostModel.swift`, `Sources/GimbalHostSupport/HostInstanceLock.swift`, `Sources/GimbalHostMac/GimbalHostApp.swift`, `scripts/build-host-mac.sh`, `scripts/check-host-bundle.sh`
- Modify: `Package.swift` (manifiesto final)
- Test: `Tests/GimbalHostSupportTests/HostModelTests.swift`

**Interfaces:**
- Consumes: Task 8 `HostRuntime`, `HostLink`, drafts, auditoría; Task 7 `MCPServerControl`; `CoreBluetoothOMTransport.connect(timeout:) async throws`, `disconnect()` y callback sincronizado.
- Produces: `@MainActor @Observable final class HostModel { init(runtime: HostRuntime, files: LocalFiles, instanceLock: HostInstanceLock? = nil, serverFactory: @escaping @MainActor (any GimbalService, String) -> any MCPServerControl, clock: RuntimeClock = .live); start() async; refresh() async; setMCPEnabled(_ enabled: Bool) async; shutdown() async; prepareZone(name: String, forbidden: Bool = false) async; confirmZone() async; cancelZone(); prepareReference() async; confirmReference() async; cancelReference(); humanStop() async; registrationCommand() -> String? }`; `HostInstanceLock.init(directory: URL) throws`; `GimbalHostMac.app`, `.build/bin/gimbal`. Solo el executable de la app crea el adapter BLE, de forma diferida al iniciar el runtime.

- [ ] **Step 1: Escribir las pruebas que fallan y el manifiesto final**

`Package.swift`:
```swift
// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "GimbalKit", targets: ["GimbalKit"]),
    .library(name: "GimbalKitSim", targets: ["GimbalKitSim"]),
    .library(name: "GimbalKitDJI", targets: ["GimbalKitDJI"]),
    .library(name: "GimbalKitBLE", targets: ["GimbalKitBLE"]),
]
var targets: [Target] = [
    .target(name: "GimbalKit"),
    .target(name: "GimbalKitSim", dependencies: ["GimbalKit"]),
    .target(name: "GimbalKitDJI", dependencies: ["GimbalKit"]),
    .target(name: "GimbalKitBLE", dependencies: ["GimbalKitDJI"]),
    .testTarget(name: "GimbalKitTests", dependencies: ["GimbalKit", "GimbalKitSim"]),
    .testTarget(name: "GimbalKitDJITests", dependencies: ["GimbalKitDJI", "GimbalKit"]),
]
#if os(macOS)
products += [
    .library(name: "GimbalKitMCP", targets: ["GimbalKitMCP"]),
    .library(name: "GimbalHostSupport", targets: ["GimbalHostSupport"]),
    .executable(name: "gimbal", targets: ["GimbalCLI"]),
    .executable(name: "GimbalHostMac", targets: ["GimbalHostMac"]),
]
targets += [
    .target(name: "GimbalKitMCP", dependencies: ["GimbalKit"]),
    .target(name: "GimbalHostSupport", dependencies: ["GimbalKit", "GimbalKitDJI", "GimbalKitMCP"]),
    .executableTarget(name: "GimbalCLI", dependencies: ["GimbalKitMCP"]),
    .executableTarget(name: "GimbalHostMac", dependencies: ["GimbalHostSupport", "GimbalKit", "GimbalKitBLE", "GimbalKitDJI", "GimbalKitMCP"]),
    .executableTarget(name: "GimbalSmoke", dependencies: ["GimbalKitBLE", "GimbalKitDJI", "GimbalKit"]),
    .testTarget(name: "GimbalKitMCPTests", dependencies: ["GimbalKitMCP", "GimbalKit"]),
    .testTarget(name: "GimbalHostSupportTests", dependencies: ["GimbalHostSupport", "GimbalKit", "GimbalKitDJI", "GimbalKitMCP", "GimbalKitSim"]),
]
#endif
let package = Package(name: "GimbalKit", platforms: [.macOS(.v14), .iOS(.v17)], products: products, targets: targets)
```

`Tests/GimbalHostSupportTests/HostModelTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit
import GimbalKitMCP
@testable import GimbalHostSupport

@MainActor final class FakeServer: MCPServerControl {
    private var continuation: CheckedContinuation<UInt16, any Error>?
    private(set) var starting = false
    private(set) var stops = 0
    let paused: Bool
    init(paused: Bool) { self.paused = paused }
    func start(port: UInt16) async throws -> UInt16 {
        starting = true
        if !paused { return port == 0 ? UInt16.max : port }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: { Task { @MainActor in await self.stop() } }
    }
    func stop() async { stops += 1; let c = continuation; continuation = nil; c?.resume(throwing: CancellationError()) }
}

@MainActor @Test func modelCancelsPendingServerStartAndCleansEndpoint() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try LocalFiles(directory: root)
    let link = FakeLink()
    let sleeper = StepSleeper()
    let clock = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let runtime = HostRuntime(makeLink: { link }, store: ZoneStore(url: root.appendingPathComponent("zones.json")), clock: clock)
    let server = FakeServer(paused: true)
    let model = HostModel(runtime: runtime, files: files, serverFactory: { _, _ in server }, clock: clock)
    await model.start()
    let enabling = Task { await model.setMCPEnabled(true) }
    #expect(await eventually { await server.starting })
    await model.setMCPEnabled(false)
    await enabling.value
    #expect(!model.mcpEnabled && model.activePort == nil && !model.serverBusy)
    #expect(server.stops > 0)
    #expect(throws: LocalFileError.missing) { try files.readEndpoint() }
    #expect(model.registrationCommand() == nil)
    await model.shutdown()
}

@MainActor @Test func modelPublishesPortAndExplicitRegistrationCommand() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try LocalFiles(directory: root)
    let link = FakeLink()
    let sleeper = StepSleeper()
    let clock = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let runtime = HostRuntime(makeLink: { link }, store: ZoneStore(url: root.appendingPathComponent("zones.json")), clock: clock)
    let model = HostModel(runtime: runtime, files: files, serverFactory: { _, _ in FakeServer(paused: false) }, clock: clock)
    model.port = 0
    await model.start(); await model.setMCPEnabled(true)
    #expect(model.mcpEnabled)
    #expect(try files.readEndpoint() == model.activePort)
    let command = try #require(model.registrationCommand())
    #expect(command.hasPrefix("claude mcp add --transport http gimbalkit http://127.0.0.1:"))
    #expect(command.contains(try files.token(create: false)))
    await model.shutdown()
    #expect(throws: LocalFileError.missing) { try files.readEndpoint() }
}

@Test func onlyOneHostCanOwnTheInstanceLock() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try LocalFiles(directory: root)
    do {
        let first = try HostInstanceLock(directory: root)
        #expect(throws: HostInstanceError.alreadyRunning) { try HostInstanceLock(directory: root) }
        withExtendedLifetime(first) {}
    }
    let next = try HostInstanceLock(directory: root)
    withExtendedLifetime(next) {}
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Expected: modelo/lock inexistentes y executable de app todavía vacío.

- [ ] **Step 3: Implementar modelo, vistas y scripts**

`Sources/GimbalHostSupport/HostInstanceLock.swift`:
```swift
import Foundation
import Darwin

public enum HostInstanceError: Error, Sendable, Equatable { case alreadyRunning, unsafeFile }
public final class HostInstanceLock: Sendable {
    private let descriptor: Int32
    public init(directory: URL) throws {
        let fd = open(directory.appendingPathComponent("host.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HostInstanceError.unsafeFile }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o777 == 0o600 else {
            close(fd); throw HostInstanceError.unsafeFile
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw HostInstanceError.alreadyRunning }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
```

`Sources/GimbalHostSupport/HostModel.swift`:
```swift
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
            let saved = try await runtime.zones()
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
```

`Sources/GimbalHostMac/GimbalHostApp.swift`:
```swift
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
```

`scripts/build-host-mac.sh`:
```bash
#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modcache"
timeout 300 swift build --disable-sandbox --scratch-path .build -c release --product GimbalHostMac
timeout 300 swift build --disable-sandbox --scratch-path .build -c release --product gimbal
HOST_APP="$PWD/.build/GimbalHostMac.app"
mkdir -p "$HOST_APP/Contents/MacOS" "$PWD/.build/bin"
cp .build/release/GimbalHostMac "$HOST_APP/Contents/MacOS/GimbalHostMac"
cp .build/release/gimbal .build/bin/gimbal
chmod +x "$HOST_APP/Contents/MacOS/GimbalHostMac" .build/bin/gimbal
cat > "$HOST_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gimbalkit.host.mac</string>
<key>CFBundleName</key><string>GimbalHostMac</string>
<key>CFBundleExecutable</key><string>GimbalHostMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Conectar y controlar el estabilizador desde GimbalKit.</string>
</dict></plist>
EOF
codesign --force --sign - "$HOST_APP"
scripts/check-host-bundle.sh "$HOST_APP"
printf 'App preparada: %s\nCLI preparada: %s\n' "$HOST_APP" "$PWD/.build/bin/gimbal"
```

`scripts/check-host-bundle.sh`:
```bash
#!/bin/zsh
set -euo pipefail
HOST_APP="${1:-.build/GimbalHostMac.app}"
HOST_PLIST="$HOST_APP/Contents/Info.plist"
plutil -lint "$HOST_PLIST"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$HOST_PLIST")" = true
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$HOST_PLIST")" = 14.0
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$HOST_PLIST")" = GimbalHostMac
test -n "$(/usr/libexec/PlistBuddy -c 'Print :NSBluetoothAlwaysUsageDescription' "$HOST_PLIST")"
test -x "$HOST_APP/Contents/MacOS/GimbalHostMac"
codesign --verify --strict "$HOST_APP"
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `chmod +x scripts/build-host-mac.sh scripts/check-host-bundle.sh`
Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build`
Run: `zsh -n scripts/build-host-mac.sh scripts/check-host-bundle.sh`
Run: `scripts/build-host-mac.sh`
Expected: modelo con servidor falso, cancelación, endpoint y exclusión de segundo anfitrión pasan; app release y CLI compilan con Swift 6, plist y firma ad hoc se verifican automáticamente. El script **solo empaqueta**, no llama a `open`, no ejecuta la app ni inicializa Bluetooth. SwiftUI, permiso TCC y hardware se validan en Task 11.

- [ ] **Step 5: Commit** (Claude): `feat: app de barra de menús y empaquetado macOS verificable`

---

### Task 11 (MANUAL, la hace Claude con Jesús y la Osmo)

**Files:**
- Modify tras medir: `docs/research/telemetria-om-se.md`, `docs/superpowers/plans/ESTADO.md`
- No modificar el driver para hacer pasar una medición; si falla, abrir una corrección concreta y repetir su prueba automática antes de volver a hardware.

**Interfaces:**
- Consumes: `.build/GimbalHostMac.app`, `.build/bin/gimbal`, herramientas `gimbal_status`, `gimbal_zones`, `gimbal_look(zone, lease_seconds <= 30)`, `gimbal_stop`.
- Produces: evidencia de límites físicos, funcionamiento UI/TCC, reconexión y protocolo con cliente real; M4 solo se marca hecho tras superar esta lista.

- [ ] Abrir `.build/GimbalHostMac.app` como app. Aceptar el permiso de Bluetooth, comprobar recuperación de la SE conectada como HID, conexión, batería y pose. No lanzar simultáneamente GimbalSmoke, Python, WebBluetooth ni otra app que controle la Osmo.
- [ ] Comprobar que cerrar el panel no detiene tick/reconexión; abrir auditoría, detener y salir. Verificar barra de menús sin icono de Dock y que un segundo proceso anfitrión queda bloqueado antes de crear CoreBluetooth.
- [ ] Guardar «mesa» quieta: escribir el nombre, preparar, **cancelar** y comprobar que no se crea; preparar de nuevo y confirmar ±10°. Relanzar y reconectar: zonas visibles, movimiento bloqueado hasta confirmación humana. Comprobar la referencia físicamente antes de confirmarla; si cambió la base/referencia, no reutilizar esas zonas.
- [ ] Activar MCP, comprobar puerto mostrado, copiar el comando y ejecutarlo en Claude Code. Verificar `initialize`, `notifications/initialized`, `tools/list` y que solo aparecen cuatro herramientas. El redactor/implementador no hace esta conexión ni configura Claude por su cuenta.
- [ ] Con la pose ya dentro de «mesa», alejarla manualmente unos 6° del centro, llamar `.build/bin/gimbal look mesa` y observar pulsos lentos. Medir pose final, overshoot, retardo máximo de orientación y tiempo real de parada. Debe acabar en banda de ±2° y permanecer en la zona; si el frenado excede 0,20 s, el retardo 0,70 s o la ganancia 1,25, **no habilitar uso habitual** hasta recalcular margen/cadencia y añadir prueba de simulación con la nueva cota.
- [ ] Repetir desde cerca de cada borde y junto a una zona prohibida creada con el formulario humano y confirmación (servidor apagado durante su creación). El navegador debe rechazar una envolvente insegura antes de mover. No crear zonas editando JSON ni añadir creación/edición de zonas a MCP.
- [ ] Solicitar una zona disjunta desde fuera: debe fallar `outsideZone`, sin movimiento. Probar dos `gimbal look` concurrentes: uno obtiene el turno, el otro `busy`. Tras llegar, mostrar «un agente tiene el control de mesa» hasta caducar el lease (≤30 s), y después indicador apagado y lease nulo.
- [ ] Durante un look, pulsar PARADA humana: la última orden física debe ser stop, el lease se revoca y no sale otra velocidad antigua. Cancelar la llamada/cerrar cliente durante un pulso: debe parar y liberar el lease. Apagar MCP durante un look: cancela herramienta, cierra conexiones y borra endpoint; la app sigue mostrando conexión.
- [ ] Apagar/encender la Osmo: estado desconectado, ninguna orden tras reconectar hasta confirmar referencia; retroceso 0,5/1/2/4/8 s, un intento a la vez. Denegar temporalmente el permiso de Bluetooth y comprobar que la UI continúa usable y PARADA/Salir no esperan los 15 s de un intento cancelado.
- [ ] Comprobar `.build/bin/gimbal status`, `zones`, `stop`, el registro de aceptación/rechazo y el token 0600, sin pegarlo en documentación/capturas públicas. Verificar que el comando copiado funciona con la versión local de Claude; si su sintaxis difiere, ajustar solo el formateador y su prueba, sin cambiar seguridad/transporte.
- [ ] Registrar cifras y resultados reales en `docs/research/telemetria-om-se.md`; actualizar `ESTADO.md` con M4 hecho o casos pendientes. Añadir nota expresa: HID/joystick sigue sin soporte, Plan 4 es iOS/Atajos. Claude hace el commit `docs: validación manual de navegación y host macOS`.

---

## Autorrevisión

- **Cobertura:** A navegador puro, firma exigida, proporcional/deadband, timeout, frescura, cancelación, simulación retardada y envolvente → Tasks 1–3. B cuatro herramientas, servicio inyectable, JSON-RPC/202, HTTP Network, puerto efímero y seguridad → Tasks 4–7 y 9. C JSON atómico, corrupto + .bak, escritura humana y audit existente en app → Tasks 4, 8, 10. D dueño único, reconexión, MenuBarExtra/LSUIElement, confirmación, parada `.app`, indicador, MCP/puerto/comando, tick 100 ms y CLI → Tasks 8–10. No hay implementación iOS/Intents ni HID.
- **Código completo:** cada fichero nuevo está íntegro; los tres miembros y las propiedades que cambian del transporte tienen reemplazos/ubicación exactos. Los manifiestos de cada fase están completos. No hay pseudocódigo, marcadores ni pasos que remitan a copiar una implementación de otra tarea.
- **Consistencia:** `PoseFeedbackDevice.poseSample`, `RuntimeClock.now/sleep`, `navigationContext/navigationPulse/haltNavigation/release`, `ZoneStore.load/save`, `LocalFiles.token/readEndpoint`, `GimbalService.status/zones/look/stop`, `MCPDispatcher.respond`, `HTTPParser.feed`, `MCPServerControl.start/stop`, `HostLink.connect/disconnect` y drafts coinciden en consumidores/productores. Los helpers de test compartidos están definidos una vez por target: `FakeService`, `session/post`, `FakeLink/StepSleeper/eventually`; no dependen de helpers privados de otro target.
- **Review Focus probado:** marcas idénticas vs caché → Task 1; envío suspendido/stop/cleanup UUID y envolvente prohibida → Task 2; retardo, cadencia, stale/timeout/cancelación → Task 3; token/permisos/symlink y corrupción → Task 4; esquema, límites, errores y notificaciones → Task 5; rebinding/smuggling/límites → Task 6; bind real, 401/403/202 y lectura incompleta con reloj inyectado → Task 7; backoff/referencia/desconexión → Task 8; CLI/error → Task 9; lifecycle/toggle cancelado/lock/plist/firma → Task 10.
- **Límites explícitos:** Task 11 valida hardware/TCC, UI y cliente Claude real. El código de los bloques no ha sido ejecutado por el redactor; las expectativas son los criterios de implementación, no resultados ya obtenidos. No afirmar que el modelo físico demuestra cotas aún no medidas.
- **Revisión local de SDK:** las interfaces instaladas de Network.framework confirman `NWListener`/`NWConnection: Sendable` desde macOS 14, callbacks `@Sendable`, `requiredLocalEndpoint` y puertos efímeros. Los callbacks saltan explícitamente a `MainActor`; no se fuerza aislamiento mediante `assumeIsolated` ni se usa una API exclusiva de macOS 26.
- **Decisiones que afectan al uso:** pulsos de 6 °/s y asentamiento; rechazo de destinos fuera del lease; éxito mantiene el lease hasta expiración; confirmación de referencia por conexión nueva; creación humana de zonas permitidas/prohibidas con el mismo formulario de ±10°; endpoint local para puerto variable; servidor stateless JSON sin SSE y sin edición de zonas. Los scripts construyen pero no lanzan.
- **Entrega:** 11 tareas: 10 con prueba automática y una final manual. Commits exclusivamente de Claude. Solo este documento se modifica durante su redacción.
