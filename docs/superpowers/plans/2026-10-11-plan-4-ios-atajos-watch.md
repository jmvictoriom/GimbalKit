# GimbalKit — Plan 4 v2: iPhone, Atajos y mando Apple Watch

> Plan de implementación futuro. No ejecutar aquí tareas de código, pruebas, builds, dispositivos ni commits.

**Goal:** Añadir una app anfitriona para iPhone, acciones de Atajos y un mando Apple Watch que envía solo STOP, mirar una zona y consultar estado. Mantener intactos el camino de movimiento y las 121 pruebas del Plan 3.

**Architecture:** El iPhone es el único dueño de CoreBluetooth. Reutiliza el HostRuntime y ZoneStore existentes. El contador síncrono MotionStopCounter crea una barrera entre una intención pendiente y cualquier STOP. Atajos y Watch pasan el token capturado antes de esperar a HostRuntime.look; este vuelve a comprobarlo tras cada suspensión previa al navegador y libera cualquier lease si un STOP completado se adelantó. Después del último guard, el controlador existente revoca el lease y rechaza pulsos de un STOP concurrente. El Watch transmite mensajes tipados por WatchConnectivity y no contiene lógica de movimiento ni de seguridad.

**Tech Stack:** Swift 6 estricto, SwiftPM, Swift Testing, SwiftUI, App Intents iOS 17+, WatchConnectivity y XcodeGen. Sin dependencias nuevas. iOS 17+, watchOS 10+, macOS 14+ para el paquete y las pruebas locales.

**Spec:** docs/superpowers/specs/2026-10-11-gimbalkit-v1-design.md (§3, §6, §8 y §9), docs/research/telemetria-om-se.md, docs/superpowers/plans/ESTADO.md, el código actual de Sources/ y Tests/, los informes auditoria-plan-4-informe{,2,3,4}.md, `.superpowers/encargo/plan-4-v2-brief.md` y `.superpowers/encargo/plan-4-v2-revision.md`.

## Global Constraints

- Este plan solo crea dos documentos. No implementar código, no ejecutar pruebas ni builds, no usar red, Bluetooth o hardware, no lanzar simuladores y no hacer commits.
- En la implementación futura, no modificar GimbalController.swift, GotoNavigator.swift, NavigationSafety.swift, OMDevice.swift, el target GimbalKitDJI ni los 121 tests actuales. En ZoneStore.swift solo cambia defaultURL. En HostRuntime.swift solo se añaden el contador compartido y el overload opcional de look; con token no nil se comprueba al entrar y después de cada suspensión anterior a `navigator.go`, en especial justo después de `requestLease`. Sin token, el flujo existente conserva su resultado y orden de efectos. No cambiar reconexión, persistencia ni auditoría.
- Añadir solo watchOS(.v10) a las plataformas del paquete. El host support y los drivers que forman parte de la app de iPhone deben compilar para iOS 17. GimbalWatchKit es el único producto que necesita el target Watch; el reloj no enlaza GimbalHostSupport, GimbalKitBLE ni CoreBluetooth.
- Aislar con #if os(macOS) el contenido actual de HostModel.swift y HostInstanceLock.swift, y todo `Sources/GimbalKitMCP/LocalFiles.swift`, cuya implementación solo usa el host macOS. El protocolo y DTO de GimbalService permanecen disponibles al runtime. El iPhone usa un PhoneHostModel nuevo sobre HostRuntime; la app iOS nunca crea HostModel, HTTPServer, LocalFiles, ni inicia un listener MCP.
- ZoneStore.defaultURL usa el primer URL de FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask) y añade GimbalKit/zones.json. Si Foundation no devuelve directorio, falla explícitamente con preconditionFailure; no usa una ruta distinta por plataforma.
- MotionStopCounter es una clase final @unchecked Sendable, con NSLock privado y un UInt64; read() e increment() son síncronos. Su callback de lectura interno solo existe bajo DEBUG, por defecto es nil y permite fijar carreras en pruebas sin añadir suspensiones. HostRuntime expone la misma instancia como nonisolated let y la recibe en un parámetro final con valor predeterminado MotionStopCounter(). La primera sentencia síncrona de stop() y humanStop() incrementa el contador, incluso sin conexión.
- Conservar el requisito exacto GimbalService.look(zone:leaseSeconds:). Añadir una sobrecarga look(zone:leaseSeconds:stopToken:); su primera sentencia comprueba el token cuando no es nil y lanza NavigationError.interrupted si cambió. El overload antiguo delega con nil. Con token, volver a comprobar después de `activeLease` y de toda suspensión previa al navegador; después de `requestLease`, si cambió, liberar el lease concedido y lanzar `.interrupted` antes de `navigator.go`. Si el STOP entra después de esa comprobación, el controlador revoca el lease y rechaza el pulso por su camino actual. No añadir nuevas épocas, tickets ni reglas al controlador.
- Atajos “Mirar a zona” captura motionStopCounter.read() antes de iniciar o esperar conexión; pasa ese mismo valor al overload nuevo. “Parar” llama directamente a humanStop() sin esperar conexión. La barrera no autoriza el movimiento: HostRuntime, GimbalController y GotoNavigator siguen validando referencia, zonas, lease y política.
- Toda espera de conexión para un intent que mira tiene límite de 10 s y respeta cancelación. Si agota el plazo o se cancela, no llama a HostRuntime.look y no produce movimiento. La lectura de estado no exige conexión.
- App Intents vive en GimbalKitIntents. Las entidades leen el mismo ZoneStore; los métodos de lógica reciben protocolos/closures Sendable y son testeables sin ejecutar App Intents. `Guardar zona aquí` prepara primero un ZoneDraft, muestra ese mismo nombre y pose para confirmar, y pasa exactamente ese draft a `confirmZone`; cancelar o cambiar de sesión/pose antes de confirmar no persiste. requestConfirmation usa la firma iOS 17 result:confirmationActionName:showPrompt:.
- No existe el intent “Mover un poco”. El Watch emite únicamente stop, look(zone) y status. Cada petición trae session: UUID y seq: UInt64; look añade operationID y el stopToken más reciente recibido del iPhone. No hay valores de velocidad ni timestamps sentAt. El token es metadato, no una cuarta orden.
- PhoneWatchService ejecuta cada STOP aunque llegue repetido o fuera de orden; solo aumenta máximos/barrera de secuencia cuando su `seq` es mayor. La mirada valida secuencia, silencio, zona y ocupación sin suspender; en esa misma sección lee el contador, reserva operationID y marca watchOperationActive antes del primer await. Las zonas admitidas se refrescan desde `runtime.zones()` al producir estado, sin depender de una vista. STOP de iPhone/Atajos y pérdida de alcance durante una mirada abren el silencio de dos segundos sincrónicamente antes de suspender.
- El puente WatchConnectivity transforma [String: Any] en DTO Sendable dentro de callbacks nonisolated y salta a @MainActor con esos DTO. Los eventos arrived/stopped llevan el token de parada capturado al aceptar la operación. Justo antes de enviar, el puente compara el contador; descarta resultados obsoletos y sustituye una llegada obsoleta por `stopped` para su operationID. `updateApplicationContext` incluye el último evento terminal y el reloj lo reduce con el mismo reducer que sendMessage, sin háptica duplicada. No usar transferUserInfo.
- El Watch ignora eventos cuyo operationID no sea el actual. Usa List/desplazamiento nativo con Digital Crown; no convierte la corona en una orden de movimiento. No enlaza BLE.
- Swift Testing, continuaciones y relojes controlados; cero pruebas con BLE, sockets o sleeps reales en las tareas automáticas. Reutilizar eventually y fixtures ya existentes; helpers nuevos tienen nombre propio y se declaran una vez en su archivo. No mover tests ni fixtures entre targets.
- Las cuatro integraciones MCP que abren loopback se conservan sin cambios y se omiten solo dentro del sandbox. Ejecutarlas aparte fuera de él: httpLoopbackUsesEphemeralPortAndChecksCredentialsAndOrigin, incompleteHTTPRequestTimesOutWithoutRealSleep, seventeenthRealLoopbackPeerIsClosedWhileSixteenRemainUsable y cliCommandsUseMCPAndBadCredentialsFail.
- Cada tarea termina con una comprobación automática local. La instalación firmada, permisos del sistema, background real, Siri, emparejamiento, alcance/háptica y Osmo quedan en la tarea manual final.
- XcodeGen se ejecuta como /opt/homebrew/bin/xcodegen desde Apps/. Los builds de simulador usan CODE_SIGNING_ALLOWED=NO; compilar no es lanzar un simulador. La firma e instalación en dispositivos reales corresponde a Jesús.

## Review Focus

- Token capturado antes de la primera espera; token viejo aborta antes de adquirir lease o enviar. Probar STOP tras el guard inicial y antes de conceder lease, y STOP tras la comprobación poslease; nil conserva el comportamiento actual.
- stop() y humanStop() incrementan primero y también sin rig conectado; todas las fachadas comparten exactamente la instancia inyectada.
- STOP entre la admisión Watch y la entrada al actor HostRuntime; STOP durante una mirada; STOP externo de iPhone/Atajos; no se emite una llegada tardía ni se acepta una mirada durante dos segundos. Verificar el contador justo antes de publicar eventos y la corrección stopped de una llegada obsoleta.
- Secuencias repetidas o desordenadas por sesión, incluidos `look seq=1`, `status seq=3`, `stop seq=2` en ese orden de entrega: STOP siempre ejecuta; solo avanza máximos/barrera si su seq es mayor. Diccionario malformado, seq no entero/no finito, identificador inválido y rechazo con el motivo real.
- Reloj fuera de alcance antes de que termine la preparación: watchOperationActive ya debe estar activo y la parada debe entrar inmediatamente.
- Dos órdenes look concurrentes, STOP mientras look espera, limpieza tardía de una operación antigua y respuesta de eventos obsoletos.
- Intents con Osmo apagada, reconexión dentro del proceso en background, límite cancelable de 10 s y cero movimiento si no conecta.
- Confirmación de “Guardar zona aquí”: API exacta, aceptación del mismo ZoneDraft (ID, sesión y pose mostrada), cancelación, error y rechazo si cambió sesión/pose; el almacenamiento queda igual al cancelar.
- Registro AppIntentsPackage con metatipos; propiedades estáticas inmutables y ProvidesDialog; frases en español.
- Portabilidad de ZoneStore, GimbalHostSupport, GimbalKitMCP/LocalFiles.swift y BLE para iOS; exclusión macOS de HostModel/HostInstanceLock/LocalFiles; 121 tests existentes sin cambios.
- `info.properties` conserva permiso Bluetooth, background, `WKApplication` y `WKCompanionAppBundleIdentifier` en plist generados; bootstrap del runtime/bridge ocurre en `GimbalPhoneApp.init` sin depender de crear la ventana. Bundle companion correcto, target Watch embebido, productos SwiftPM locales y builds de ambos simuladores.
- Pérdida de alcance fija quietUntil antes del await; estado actualiza zonas admitidas desde el runtime; application context recupera el evento terminal y la deduplicación no repite háptica.
- El reloj solo envía tres órdenes, no abre CoreBluetooth y su Digital Crown solo desplaza zonas.

## File Structure

~~~text
Package.swift
Sources/GimbalKit/ZoneStore.swift                  # defaultURL portable; ningún otro cambio
Sources/GimbalKitMCP/LocalFiles.swift              # implementación macOS-only para compilar GimbalHostSupport en iOS
Sources/GimbalHostSupport/
  HostRuntime.swift                                # counter + overload stopToken + guardias tras suspensiones pre-navegador
  HostModel.swift                                  # cuerpo actual bajo #if os(macOS)
  HostInstanceLock.swift                           # cuerpo actual bajo #if os(macOS)
  MotionStopCounter.swift                          # nuevo
  CoreBluetoothHostLink.swift                      # nuevo; solo iOS
  PhoneHostEnvironment.swift                       # nuevo; runtime único y wait cancelable
  PhoneHostModel.swift                             # nuevo; UI iPhone sobre HostRuntime y draft confirmado
  PhoneWatchService.swift                          # nuevo; secuencias, STOP, silencio, zonas y terminales
Sources/GimbalKitIntents/
  GimbalIntentActionService.swift                  # lógica pura testeable
  GimbalKitIntents.swift                           # ZoneEntity, intents y shortcuts
Sources/GimbalWatchKit/
  WatchMessages.swift                              # DTO Sendable y codec de diccionarios
Tests/GimbalHostSupportTests/
  MotionStopCounterAndRuntimeStopTokenTests.swift  # nuevo
  PhoneHostModelTests.swift                        # nuevo
  PhoneWatchServiceTests.swift                     # nuevo
Tests/GimbalKitIntentsTests/
  GimbalIntentActionServiceTests.swift             # nuevo
Tests/GimbalWatchKitTests/
  WatchMessagesTests.swift                        # nuevo
Apps/project.yml
Apps/GimbalPhone/
  GimbalPhoneApp.swift
  PhoneHomeView.swift
  PhoneWatchBridge.swift
Apps/GimbalWatch/
  GimbalWatchApp.swift
  WatchHomeView.swift
  WatchConnectivityClient.swift
~~~

---

### Task 1 — Portabilidad, contador síncrono y token aditivo en HostRuntime

**Files:**
- Modify: Package.swift, Sources/GimbalKit/ZoneStore.swift, Sources/GimbalKitMCP/LocalFiles.swift, Sources/GimbalHostSupport/HostRuntime.swift, Sources/GimbalHostSupport/HostModel.swift, Sources/GimbalHostSupport/HostInstanceLock.swift
- Create: Sources/GimbalHostSupport/MotionStopCounter.swift, Tests/GimbalHostSupportTests/MotionStopCounterAndRuntimeStopTokenTests.swift

**Interfaces:**
- Preserves: todas las firmas actuales de HostRuntime, incluida GimbalService.look(zone:leaseSeconds:), y toda la conducta sin token.
- Produces: MotionStopCounter.read() -> UInt64, increment() -> UInt64; HostRuntime.init(..., motionStopCounter: MotionStopCounter = MotionStopCounter()); nonisolated let motionStopCounter; overload look(zone: String, leaseSeconds: Double, stopToken: UInt64?) async throws -> GimbalLookResult.
- Portability: ZoneStore.defaultURL obtiene Application Support de Foundation. El contenido actual de HostModel.swift, HostInstanceLock.swift y LocalFiles.swift queda bajo #if os(macOS) sin cambiar sus cuerpos. GimbalHostSupport sigue disponible desde el manifest que usa XcodeGen en Mac; su módulo compila para iOS.

- [ ] **Step 1: Añadir pruebas rojas, sin cambiar las pruebas existentes**

Añadir en MotionStopCounterAndRuntimeStopTokenTests.swift pruebas Swift Testing para: incrementos concurrentes con valor final exacto; stop() y humanStop() incrementan aun sin rig; un token antiguo lanza NavigationError.interrupted antes de conectar/adquirir lease/enviar; token vigente entra en el camino existente; la llamada antigua sin token mantiene su error/resultado actual. Añadir además estas carreras reales con HostRuntime: (a) en DEBUG, un callback de prueba síncrono del counter cambia el valor en su tercera lectura (entrada, retorno de activeLease, retorno de requestLease); el token poslease debe fallar, liberar el lease concedido y no escribir SPEED; (b) con lease concedido y token ya comprobado, completar humanStop antes de alimentar nuevas muestras, reanudar el navegador y comprobar que el controlador rechaza el pulso, no queda lease y no aparece SPEED después de STOP. Coordinar el primer caso con el callback test-only y el segundo con continuaciones/RuntimeClock manual, nunca con sleeps reales; no reemplazar estas carreras por una prueba que solo entra con un token ya obsoleto.

Para el caso sin rig, el factory debe contar llamadas y fallar si se invoca. Para probar el camino con rig, reutilizar FakeLink, LinkFactory, StepSleeper y eventually ya declarados en HostRuntimeTests.swift; no volver a declararlos. La referencia sin confirmar hace que un token vigente llegue al mismo NavigationError.referenceRequired que la llamada antigua; no necesita mover hardware simulado. En las carreras, confirma zona y referencia con el mismo FakeLink; detecta SPEED en `writes` filtrando frames `OMRotate` de comando `0x0C` cuyo payload yaw/pitch/roll (bytes 11...16) contenga un valor distinto de cero. La prueba de lease concedido toma una instantánea de `writes` al completar humanStop y comprueba que ninguna velocidad no nula aparece después.

~~~swift
import Foundation
import Testing
import GimbalKit
@testable import GimbalHostSupport

@Test func stopCounterIsSynchronousAndThreadSafe() async {
    let counter = MotionStopCounter()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                for _ in 0..<1_000 { counter.increment() }
            }
        }
    }
    #expect(counter.read() == 8_000)
}

@Test func oldStopTokenAbortsBeforeConnectingOrMoving() async throws {
    let counter = MotionStopCounter()
    let factory = LinkFactory([FakeLink()])
    let runtime = HostRuntime(
        makeLink: { factory.next() },
        store: ZoneStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        motionStopCounter: counter
    )
    let oldToken = counter.read()
    await runtime.humanStop()
    #expect(counter.read() == oldToken + 1)
    await #expect(throws: NavigationError.interrupted) {
        try await runtime.look(zone: "mesa", leaseSeconds: 30, stopToken: oldToken)
    }
    #expect(counter.read() == oldToken + 1)
    #expect(factory.attempts == 0)
}

@Test func stopAndHumanStopIncrementEvenWithoutARig() async throws {
    let counter = MotionStopCounter()
    let runtime = HostRuntime(
        makeLink: { FakeLink() },
        store: ZoneStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        motionStopCounter: counter
    )
    try await runtime.stop()
    #expect(counter.read() == 1)
    await runtime.humanStop()
    #expect(counter.read() == 2)
}

@Test func currentTokenReachesTheExistingReferenceGuard() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = FakeLink()
    let sleeper = StepSleeper()
    let clock = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let counter = MotionStopCounter()
    let runtime = HostRuntime(
        makeLink: { link },
        store: ZoneStore(url: root.appendingPathComponent("zones.json")),
        clock: clock,
        motionStopCounter: counter
    )
    try await runtime.start()
    #expect(await eventually { (try? await runtime.status().connected) == true })
    await link.attitude()
    #expect(await eventually { (try? await runtime.status().pose) != nil })
    let token = counter.read()
    await #expect(throws: NavigationError.referenceRequired) {
        try await runtime.look(zone: "mesa", leaseSeconds: 30, stopToken: token)
    }
    await runtime.shutdown()
}

private final class CounterReadStopProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var counter: MotionStopCounter?
    private var readsUntilStop: Int?

    func attach(_ counter: MotionStopCounter) { lock.withLock { self.counter = counter } }
    func arm(afterReads count: Int) { lock.withLock { readsUntilStop = count } }

    func didRead() {
        let target = lock.withLock { () -> MotionStopCounter? in
            guard let readsUntilStop else { return nil }
            if readsUntilStop == 1 {
                self.readsUntilStop = nil
                return counter
            }
            self.readsUntilStop = readsUntilStop - 1
            return nil
        }
        target?.increment()
    }
}

private final class CounterReadSignalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var readsUntilSignal: Int?

    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }
    func arm(afterReads count: Int) { lock.withLock { readsUntilSignal = count } }

    func didRead() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard let readsUntilSignal else { return false }
            if readsUntilSignal == 1 {
                self.readsUntilSignal = nil
                return true
            }
            self.readsUntilSignal = readsUntilSignal - 1
            return false
        }
        if shouldSignal { continuation.yield(()) }
    }

    func waitUntilSignalled() async {
        for await _ in stream { break }
    }
}

private func containsNonzeroSpeedFrame(_ frames: [[UInt8]]) -> Bool {
    frames.contains { frame in
        guard frame.count >= 19, frame[10] == 0x0C else { return false }
        return frame[11...16].contains { $0 != 0 }
    }
}

@Test func stopCounterChangingAfterRequestLeaseReleasesTheNewLease() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = FakeLink()
    let sleeper = StepSleeper()
    let clock = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let probe = CounterReadStopProbe()
    let counter = MotionStopCounter(onRead: { probe.didRead() })
    probe.attach(counter)
    let runtime = HostRuntime(makeLink: { link }, store: ZoneStore(url: root.appendingPathComponent("zones.json")),
                              clock: clock, motionStopCounter: counter)
    try await runtime.start()
    #expect(await eventually { (try? await runtime.status().connected) == true })
    await link.attitude()
    #expect(await eventually { (try? await runtime.status().pose) != nil })
    let draft = try await runtime.prepareZone(name: "mesa")
    try await runtime.confirmZone(draft)
    let token = counter.read()

    probe.arm(afterReads: 3)
    await #expect(throws: NavigationError.interrupted) {
        try await runtime.look(zone: "mesa", leaseSeconds: 30, stopToken: token)
    }
    #expect(counter.read() == token + 1)
    #expect(try await runtime.status().lease == nil)
    #expect(!containsNonzeroSpeedFrame(await link.writes))
    await runtime.shutdown()
}

@Test func stopAfterLeaseGrantRevokesBeforeTheNextSpeedPulse() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = FakeLink()
    let sleeper = StepSleeper()
    let clock = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let probe = CounterReadSignalProbe()
    let counter = MotionStopCounter(onRead: { probe.didRead() })
    let runtime = HostRuntime(makeLink: { link }, store: ZoneStore(url: root.appendingPathComponent("zones.json")),
                              clock: clock, motionStopCounter: counter)
    try await runtime.start()
    #expect(await eventually { (try? await runtime.status().connected) == true })
    await link.attitude()
    #expect(await eventually { (try? await runtime.status().pose) != nil })
    let draft = try await runtime.prepareZone(name: "mesa")
    try await runtime.confirmZone(draft)
    let token = counter.read()
    probe.arm(afterReads: 3)
    let look = Task { try await runtime.look(zone: "mesa", leaseSeconds: 30, stopToken: token) }
    await probe.waitUntilSignalled()
    #expect(try await runtime.status().lease != nil)
    let writesAtCheck = await link.writes
    let writesBeforeStop = writesAtCheck.count
    await runtime.humanStop()
    await sleeper.advance(0.1)
    let lookResult = await look.result
    #expect({ if case .failure = lookResult { true } else { false } }())
    let writes = await link.writes
    #expect(!containsNonzeroSpeedFrame(Array(writes.dropFirst(writesBeforeStop))))
    #expect(try await runtime.status().lease == nil)
    await runtime.shutdown()
}

@Test func nilTokenKeepsTheExistingDisconnectedLookError() async throws {
    let runtime = HostRuntime(
        makeLink: { FakeLink() },
        store: ZoneStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )
    await #expect(throws: SafetyViolation.poseUnavailable) {
        try await runtime.look(zone: "mesa", leaseSeconds: 30)
    }
}
~~~

Expected red: MotionStopCounter, su inicializador de probe DEBUG, el parámetro del inicializador HostRuntime y el overload aún no existen. El probe solo puede disparar una vez y se compila en DEBUG; el inicializador público normal deja `read()` sin callback.

- [ ] **Step 2: Implementar el contador y cambiar solo las sentencias indicadas**

MotionStopCounter.swift completo:

~~~swift
import Foundation

/// Contador compartido entre actores. El lock protege tanto lectura como incremento.
public final class MotionStopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    #if DEBUG
    private let onRead: (@Sendable () -> Void)?
    #endif

    public init() {
        #if DEBUG
        onRead = nil
        #endif
    }

    #if DEBUG
    init(onRead: @escaping @Sendable () -> Void) {
        self.onRead = onRead
    }
    #endif

    public func read() -> UInt64 {
        #if DEBUG
        onRead?()
        #endif
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    public func increment() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        precondition(value < UInt64.max, "MotionStopCounter agotado")
        value += 1
        return value
    }
}
~~~

En HostRuntime.swift, añadir public nonisolated let motionStopCounter, inicializarla desde el parámetro final con default, y poner motionStopCounter.increment() como primera sentencia de stop() y humanStop(). Mantener el resto de ambas funciones byte por byte.

El inicializador queda con la firma completa siguiente:

~~~swift
public init(
    makeLink: @escaping @Sendable () -> any HostLink,
    store: ZoneStore,
    clock: RuntimeClock = .live,
    motionStopCounter: MotionStopCounter = MotionStopCounter()
) {
    self.makeLink = makeLink
    self.store = store
    self.clock = clock
    self.motionStopCounter = motionStopCounter
}
~~~

Las dos funciones conservan sus cuerpos actuales después de la primera línea:

~~~swift
public func stop() async throws {
    motionStopCounter.increment()
    if let rig { await rig.controller.stop(source: .agent("mcp")) }
}

public func humanStop() async {
    motionStopCounter.increment()
    if let rig { await rig.controller.stop(source: .app) }
}
~~~

Mantener el requisito de protocolo con dos overloads; trasladar el cuerpo actual de look(zone:leaseSeconds:) al overload nuevo. Con token `nil`, el cuerpo original conserva su orden; con token, comprobar en la entrada y tras las suspensiones anteriores a `navigator.go`:

~~~swift
public func look(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult {
    try await look(zone: zone, leaseSeconds: leaseSeconds, stopToken: nil)
}

public func look(zone: String, leaseSeconds: Double, stopToken: UInt64?) async throws -> GimbalLookResult {
    if let stopToken {
        guard motionStopCounter.read() == stopToken else { throw NavigationError.interrupted }
    }
    guard let captured = rig else { throw SafetyViolation.poseUnavailable }
    guard referenceReady else { throw NavigationError.referenceRequired }
    guard leaseSeconds.isFinite, leaseSeconds > 0, leaseSeconds <= 30 else { throw SafetyViolation.invalidDuration }
    guard !looking, !editing else { throw NavigationError.busy }
    looking = true
    defer { looking = false }
    let existingLease = await captured.controller.activeLease
    if let stopToken {
        guard motionStopCounter.read() == stopToken else { throw NavigationError.interrupted }
    }
    if let existingLease { throw SafetyViolation.busy(holder: existingLease.source) }
    guard rig?.id == captured.id, referenceReady else { throw NavigationError.interrupted }
    let lease: Lease
    do {
        lease = try await captured.controller.requestLease(source: .agent("mcp"), zone: zone, seconds: leaseSeconds)
    } catch {
        if let stopToken {
            guard motionStopCounter.read() == stopToken else { throw NavigationError.interrupted }
        }
        throw error
    }
    if let stopToken {
        guard motionStopCounter.read() == stopToken else {
            await captured.controller.release(lease: lease)
            throw NavigationError.interrupted
        }
    }
    do {
        let arrival = try await captured.navigator.go(to: zone, source: .agent("mcp"), lease: lease)
        return GimbalLookResult(status: try await status(), arrivalPose: arrival)
    } catch {
        await captured.controller.release(lease: lease)
        throw error
    }
}
~~~

ZoneStore.defaultURL:

~~~swift
public static var defaultURL: URL {
    guard let support = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first else {
        preconditionFailure("Application Support no está disponible")
    }
    return support.appendingPathComponent("GimbalKit").appendingPathComponent("zones.json")
}
~~~

En HostModel.swift, HostInstanceLock.swift y LocalFiles.swift, insertar literalmente `#if os(macOS)` antes del primer import y `#endif` después de la última declaración. No editar ni reordenar sus imports o declaraciones; así no se compila `FileManager.homeDirectoryForCurrentUser` en iOS y quedan disponibles GimbalService y sus DTO en GimbalKitMCP.

`Sources/GimbalKitMCP/LocalFiles.swift` queda íntegramente dentro de esta condición de plataforma; este es el archivo completo resultante (su implementación macOS permanece byte por byte):

~~~swift
#if os(macOS)
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
#endif
~~~

Añadir .watchOS(.v10) a Package.swift. No condicionar el target GimbalHostSupport por el destino del producto: el manifest se evalúa en el Mac que genera el proyecto. No mover targets ni tests.

- [ ] **Step 3: Ejecutar prueba focalizada y build macOS**

~~~sh
CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter MotionStopCounterAndRuntimeStopTokenTests
CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift build --disable-sandbox --scratch-path .build
~~~

Expected: contador, overloads y portabilidad compilan en macOS; las pruebas del token antiguo, token vigente, nil y ambos STOP pasan.

- [ ] **Step 4: Ejecutar la suite sin las cuatro pruebas de socket**

~~~sh
CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build \
  --skip httpLoopbackUsesEphemeralPortAndChecksCredentialsAndOrigin \
  --skip incompleteHTTPRequestTimesOutWithoutRealSleep \
  --skip seventeenthRealLoopbackPeerIsClosedWhileSixteenRemainUsable \
  --skip cliCommandsUseMCPAndBadCredentialsFail
~~~

Expected: las 121 pruebas existentes sin modificar y la prueba nueva pasan. Ejecutar esas cuatro pruebas solo fuera del sandbox, cada una con el mismo scratch path y timeout.

---

### Task 2 — Host iPhone único y espera cancelable de conexión

**Files:**
- Modify: Package.swift
- Create: Sources/GimbalHostSupport/CoreBluetoothHostLink.swift, Sources/GimbalHostSupport/PhoneHostEnvironment.swift, Sources/GimbalHostSupport/PhoneHostModel.swift, Tests/GimbalHostSupportTests/PhoneHostModelTests.swift

**Interfaces:**
- Consumes: HostRuntime, HostLink, CoreBluetoothOMTransport, ZoneStore, RuntimeClock, DTO de GimbalService.
- Produces: PhoneHostEnvironment.shared.runtime, motionStopCounter, start(), waitUntilConnected(timeout: 10); PhoneHostModel.start/refresh/look/humanStop/prepareZone(name:forbidden:), cancelZone(_:), confirmZone(_:ZoneDraft)/prepareReference/confirmReference.
- La app y App Intents reciben la misma instancia de PhoneHostEnvironment; no hay una segunda conexión Bluetooth. waitUntilConnected llama primero a runtime.start(), consulta runtime.status() hasta conexión, duerme con el RuntimeClock inyectado, falla al llegar a 10 s y propaga cancelación.
- En Package.swift, añadir GimbalKitBLE a la lista de dependencias del target GimbalHostSupport; mantener el target bajo el bloque de manifest existente para macOS.

- [ ] **Step 1: Pruebas rojas de timeout, cancelación, estado y confirmación del mismo draft**

Añadir pruebas con FakeLink, StepSleeper y zona temporal. Hacer que la espera avance el reloj manual a 10 s y comprobar que arroja timeout y que el fake no recibe ningún look; cancelar la tarea durante una espera bloqueada y comprobar CancellationError; alimentar una pose con FakeLink.attitude() y verificar status, zonas, guardado tras confirmación, cancelación sin escritura y parada humana. `prepareZone(name:forbidden:)` devuelve el ZoneDraft preparado; guardar pasa exactamente ese valor a la confirmación y luego a `confirmZone(_:)`. Añadir casos en que, mientras el diálogo está abierto, se desconecta/reconecta el rig o cambia la pose fuera de la tolerancia vigente: confirmar el draft mostrado termina con `.interrupted` y el almacén sigue vacío. Añadir `environmentStartsWithoutCreatingAView`: iniciar PhoneHostEnvironment con FakeLink y comprobar que runtime.status pasa a connected sin construir PhoneHomeView ni crear una escena. No dormir ni crear CoreBluetoothOMTransport en los tests.

PhoneHostModelTests.swift no debe volver a declarar helpers ya presentes en HostRuntimeTests.swift. Para probar cancelación del borrador de UI, comprobar model.zoneDraft == nil y que ZoneStore.load() sigue vacío.

- [ ] **Step 2: Añadir el adapter y entorno compartido**

CoreBluetoothHostLink.swift contiene este adapter completo; GimbalHostMac/GimbalHostApp.swift no se modifica:

~~~swift
import Foundation
import GimbalKitDJI
import GimbalKitBLE

#if os(iOS)
public final class CoreBluetoothHostLink: HostLink, Sendable {
    public let transport: CoreBluetoothOMTransport
    public let disconnects: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    public var notifications: AsyncStream<[UInt8]> { transport.notifications }

    public init() {
        let pair = AsyncStream.makeStream(of: Void.self)
        disconnects = pair.stream
        continuation = pair.continuation
        transport = CoreBluetoothOMTransport()
        transport.onDisconnect = { pair.continuation.yield(()) }
    }

    public func connect() async throws { try await transport.connect(timeout: 15) }
    public func disconnect() async { transport.disconnect(); continuation.finish() }
    public func write(_ bytes: [UInt8]) async throws { try await transport.write(bytes) }
}
#endif
~~~

PhoneHostEnvironment construye una sola instancia de contador/runtime y acepta makeLink, ZoneStore y RuntimeClock en un init de pruebas. shared usa CoreBluetoothHostLink, ZoneStore() y .live. Mantener el link protegido por #if os(iOS) para que el producto portable no exponga BLE al target Watch.

Firma del gate:

~~~swift
public func waitUntilConnected(timeout: Double = 10) async throws
~~~

Implementar el plazo con el reloj inyectado: deadline tomado antes del bucle; en cada iteración comprobar cancelación, consultar status().connected, y dormir como máximo 0,1 s o el resto. Una respuesta conectada durante la última consulta gana al timeout. No llamar a look desde el gate.

PhoneHostEnvironment.swift define el error y el entorno completo:

~~~swift
import Foundation
import GimbalKit

public enum PhoneConnectionError: Error, Sendable, Equatable {
    case timedOut
}

public final class PhoneHostEnvironment: Sendable {
    #if os(iOS)
    public static let shared = PhoneHostEnvironment(
        makeLink: { CoreBluetoothHostLink() },
        store: ZoneStore(),
        clock: .live
    )
    #endif

    public let runtime: HostRuntime
    public let motionStopCounter: MotionStopCounter
    public let clock: RuntimeClock

    public init(
        makeLink: @escaping @Sendable () -> any HostLink,
        store: ZoneStore,
        clock: RuntimeClock = .live
    ) {
        let counter = MotionStopCounter()
        self.motionStopCounter = counter
        self.clock = clock
        self.runtime = HostRuntime(
            makeLink: makeLink,
            store: store,
            clock: clock,
            motionStopCounter: counter
        )
    }

    public func start() async throws {
        try await runtime.start()
    }

    public func waitUntilConnected(timeout: Double = 10) async throws {
        guard timeout.isFinite, timeout > 0 else { throw PhoneConnectionError.timedOut }
        try await runtime.start()
        let deadline = clock.now().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if try await runtime.status().connected { return }
            let remaining = deadline.timeIntervalSince(clock.now())
            guard remaining > 0 else { throw PhoneConnectionError.timedOut }
            try await clock.sleep(min(0.1, remaining))
        }
    }
}
~~~

PhoneHostModel es @MainActor @Observable, almacena status, zonas, audit, borradores visibles y error; lee/escribe mediante HostRuntime. look(zone:) lee el contador antes de cualquier await, espera conexión con el gate y llama al overload con ese token. `prepareZone(name:forbidden:)` devuelve y conserva el ZoneDraft exacto que se mostrará; `confirmZone(_:)` exige que siga siendo el borrador actual y pasa ese mismo valor al runtime; `cancelZone(_:)` solo limpia ese borrador. humanStop() llama directamente a runtime.humanStop(). El botón de STOP nunca espera conexión.

PhoneHostModel.swift completo:

~~~swift
import Foundation
import Observation
import GimbalKit
import GimbalKitMCP

@MainActor @Observable
public final class PhoneHostModel {
    public private(set) var status = GimbalStatus(
        connected: false, referenceReady: false, battery: nil, pose: nil, lease: nil
    )
    public private(set) var zones: [ZoneRecord] = []
    public private(set) var audit: [AuditEntry] = []
    public private(set) var zoneDraft: ZoneDraft?
    public private(set) var referenceDraft: ReferenceDraft?
    public var errorMessage: String?

    @ObservationIgnored private let environment: PhoneHostEnvironment
    @ObservationIgnored private var poller: Task<Void, Never>?

    public init(environment: PhoneHostEnvironment) {
        self.environment = environment
    }

    public func start() async {
        guard poller == nil else { return }
        do {
            try await environment.start()
            await refresh()
            let clock = environment.clock
            poller = Task { [weak self, clock] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refresh()
                    do { try await clock.sleep(0.2) } catch { return }
                }
            }
        } catch {
            errorMessage = "No se pudo iniciar la conexión."
        }
    }

    public func refresh() async {
        do {
            let newStatus = try await environment.runtime.status()
            let newZones = await environment.runtime.zones()
            let newAudit = await environment.runtime.auditEntries()
            status = newStatus
            zones = newZones
            audit = newAudit
        } catch {
            errorMessage = "No se pudo actualizar el estado."
        }
    }

    public func look(zone: String) async {
        let token = environment.motionStopCounter.read()
        do {
            try await environment.waitUntilConnected(timeout: 10)
            _ = try await environment.runtime.look(zone: zone, leaseSeconds: 30, stopToken: token)
            await refresh()
        } catch {
            errorMessage = "No se pudo mirar a \(zone). Compruebe conexión, referencia y zona."
        }
    }

    public func humanStop() async {
        await environment.runtime.humanStop()
        await refresh()
    }

    public func prepareZone(name: String, forbidden: Bool = false) async -> ZoneDraft? {
        do {
            let draft = try await environment.runtime.prepareZone(name: name, forbidden: forbidden)
            zoneDraft = draft
            return draft
        } catch {
            zoneDraft = nil
            errorMessage = "No se pudo preparar la zona; compruebe pose y nombre."
            return nil
        }
    }

    public func cancelZone(_ draft: ZoneDraft? = nil) {
        if let draft, zoneDraft?.id != draft.id { return }
        zoneDraft = nil
    }

    public func confirmZone(_ draft: ZoneDraft) async {
        guard zoneDraft?.id == draft.id, zoneDraft?.session == draft.session else {
            errorMessage = "El borrador cambió; vuelva a preparar la zona."
            return
        }
        zoneDraft = nil
        do {
            try await environment.runtime.confirmZone(draft)
            await refresh()
        } catch {
            errorMessage = "La conexión o pose cambió; vuelva a preparar la zona."
        }
    }

    public func prepareReference() async {
        do { referenceDraft = try await environment.runtime.prepareReference() }
        catch { errorMessage = "No hay una pose fresca para preparar la referencia." }
    }

    public func cancelReference() { referenceDraft = nil }

    public func confirmReference() async {
        guard let draft = referenceDraft else { return }
        referenceDraft = nil
        do {
            try await environment.runtime.confirmReference(draft)
            await refresh()
        } catch {
            errorMessage = "La pose cambió; vuelva a preparar la referencia."
        }
    }

    public func shutdown() async {
        poller?.cancel()
        poller = nil
        await environment.runtime.shutdown()
    }
}
~~~

- [ ] **Step 3: Probar el modelo y el gate**

~~~sh
CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter PhoneHostModelTests
CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift build --disable-sandbox --scratch-path .build
~~~

Expected: timeout y cancelación controlados, sin look al fallar el gate; guardar exige confirmación; cancelación no persiste; Swift 6 compila GimbalHostSupport. No ejecutar pruebas BLE.

---

### Task 3 — Acciones App Intents y entidades de zonas

**Files:**
- Modify: Package.swift (añadir dependencia GimbalKitMCP al target GimbalKitIntents)
- Create: Sources/GimbalKitIntents/GimbalIntentActionService.swift, Sources/GimbalKitIntents/GimbalKitIntents.swift, Tests/GimbalKitIntentsTests/GimbalIntentActionServiceTests.swift

**Interfaces:**
- Consumes: PhoneHostEnvironment.shared, HostRuntime, ZoneStore, ZoneRecord, ZoneDraft, RuntimeClock.
- Produces: GimbalKitIntentsPackage; ZoneEntity: AppEntity; ZoneEntityQuery: EntityQuery; intents LookAtZoneIntent, StopGimbalIntent, GimbalStatusIntent, SaveZoneHereIntent; GimbalIntentActionService. `saveZone(name:forbidden:runtime:confirm:)` prepara antes de pedir confirmación y confirma exactamente el mismo ZoneDraft.
- Ningún intent cambia la política o accede al controlador. No existe intent de movimiento relativo.
- Dentro de #if os(macOS), añadir el producto GimbalKitIntents, el target con dependencias GimbalKit/GimbalKitMCP/GimbalHostSupport y el testTarget GimbalKitIntentsTests. Las declaraciones se colocan junto a GimbalHostSupport; AppIntents solo compila dentro del bloque #if os(iOS) de GimbalKitIntents.swift.

- [ ] **Step 1: Probar la lógica sin ejecutar App Intents**

GimbalIntentActionServiceTests.swift usa un fake que implementa el protocolo Sendable del servicio y un closure de conexión controlada. Cubrir: look captura token antes de llamar al closure de espera; si ese closure incrementa el contador, el fake runtime observa el token viejo y no recibe look; Stop invoca humanStop sin esperar; Status devuelve estado aunque no haya conexión; SaveZone cancelado prepara una sola vez el draft mostrado, no confirma ni persiste; aceptación confirma exactamente el mismo ZoneDraft (id, session, zone y pose) que devolvió prepareZone. El fake cambia de sesión o pose antes de confirmZone en pruebas separadas y debe rechazar con `.interrupted`, sin escribir zona.

Al fake que compruebe tokens se le exige el mismo guard de entrada que HostRuntime; la prueba concreta de ese guard vive en Task 1 y no se sustituye por una aserción sobre el closure.

- [ ] **Step 2: Implementar el servicio puro y las entidades**

La orquestación de acciones no importa AppIntents; recibe runtime y wait closure para probar el orden de los efectos. `saveZone` conserva el ZoneDraft devuelto por `prepareZone` en la misma llamada asíncrona y solo lo entrega a `confirmZone` después de que el closure humano acepta ese valor.

~~~swift
import Foundation
import GimbalKit
import GimbalKitMCP
import GimbalHostSupport

public protocol GimbalIntentRuntime: Sendable {
    var motionStopCounter: MotionStopCounter { get }
    func look(zone: String, leaseSeconds: Double, stopToken: UInt64?) async throws -> GimbalLookResult
    func humanStop() async
    func status() async throws -> GimbalStatus
    func prepareZone(name: String, forbidden: Bool) async throws -> ZoneDraft
    func confirmZone(_ draft: ZoneDraft) async throws
}

extension HostRuntime: GimbalIntentRuntime {}

public enum GimbalIntentActionService {
    public static func look(
        zone: String,
        runtime: any GimbalIntentRuntime,
        waitUntilConnected: @Sendable () async throws -> Void
    ) async throws -> GimbalLookResult {
        let token = runtime.motionStopCounter.read()
        try await waitUntilConnected()
        return try await runtime.look(zone: zone, leaseSeconds: 30, stopToken: token)
    }

    public static func stop(runtime: any GimbalIntentRuntime) async {
        await runtime.humanStop()
    }

    public static func status(runtime: any GimbalIntentRuntime) async throws -> GimbalStatus {
        try await runtime.status()
    }

    public static func saveZone(
        name: String,
        forbidden: Bool = false,
        runtime: any GimbalIntentRuntime,
        confirm: @Sendable (ZoneDraft) async throws -> Void
    ) async throws {
        let draft = try await runtime.prepareZone(name: name, forbidden: forbidden)
        try await confirm(draft)
        try await runtime.confirmZone(draft)
    }

    public static func statusSummary(_ status: GimbalStatus) -> String {
        let connection = status.connected ? "Conectada" : "Desconectada"
        let battery = status.battery.map { "\($0.percent)%" } ?? "no disponible"
        let pose = status.pose.map { "yaw \($0.yaw.rounded())°, pitch \($0.pitch.rounded())°" } ?? "pose no disponible"
        return "Conexión: \(connection). Batería: \(battery). \(pose)."
    }
}
~~~

GimbalIntentRuntime declara solo counter, look, humanStop, status, prepareZone y confirmZone; HostRuntime lo satisface mediante extensión. SaveZoneHereIntent prepara el ZoneDraft antes de presentar la confirmación, incluye en el diálogo su zona y pose capturadas, y confirma ese mismo valor al aceptar. Si se cancela, la acción termina sin llamar a confirmZone ni guardar; si el runtime detecta que cambió sesión o pose, rechaza y no persiste.

ZoneEntityQuery crea ZoneStore(), carga zonas, convierte a ZoneEntity(id: zone.name, name: zone.name), y filtra las entidades solicitadas. No enumera referencias ni zonas prohibidas como destinos de mirada; el runtime sigue rechazando cualquier destino no permitido.

- [ ] **Step 3: Añadir los cuatro intents y el proveedor**

GimbalKitIntents.swift compila los tipos App Intents solo en iOS; el servicio puro compila también en macOS para swift test. Registrar el paquete y usar resultados que declaran diálogo:

~~~swift
#if os(iOS)
import AppIntents
import GimbalHostSupport
import GimbalKit
import GimbalKitMCP

public struct GimbalKitIntentsPackage: AppIntentsPackage {
    public static var includedPackages: [any AppIntentsPackage.Type] { [] }
}

public struct ZoneEntity: AppEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Zona")
    public static let defaultQuery = ZoneEntityQuery()
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

public struct ZoneEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ZoneEntity] {
        let zones = try await ZoneStore().load()
        return zones
            .filter { !$0.forbidden && identifiers.contains($0.name) }
            .map { ZoneEntity(id: $0.name, name: $0.name) }
    }

    public func suggestedEntities() async throws -> [ZoneEntity] {
        try await ZoneStore().load()
            .filter { !$0.forbidden }
            .map { ZoneEntity(id: $0.name, name: $0.name) }
    }
}

public struct LookAtZoneIntent: AppIntent {
    public static let title: LocalizedStringResource = "Mirar a zona"
    public static let description = IntentDescription("Mueve el estabilizador a una zona guardada.")
    public static let openAppWhenRun = false
    @Parameter(title: "Zona") public var zone: ZoneEntity

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let environment = PhoneHostEnvironment.shared
        _ = try await GimbalIntentActionService.look(
            zone: zone.name,
            runtime: environment.runtime,
            waitUntilConnected: { try await environment.waitUntilConnected(timeout: 10) }
        )
        return .result(dialog: "Mirando a \(zone.name).")
    }
}

public struct StopGimbalIntent: AppIntent {
    public static let title: LocalizedStringResource = "Parar"
    public static let description = IntentDescription("Detiene el estabilizador.")
    public static let openAppWhenRun = false

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        await GimbalIntentActionService.stop(runtime: PhoneHostEnvironment.shared.runtime)
        return .result(dialog: "Estabilizador parado.")
    }
}

public struct GimbalStatusIntent: AppIntent {
    public static let title: LocalizedStringResource = "Estado"
    public static let description = IntentDescription("Lee conexión, batería y pose.")
    public static let openAppWhenRun = false

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = try await GimbalIntentActionService.status(runtime: PhoneHostEnvironment.shared.runtime)
        let text = GimbalIntentActionService.statusSummary(status)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

public struct SaveZoneHereIntent: AppIntent {
    public static let title: LocalizedStringResource = "Guardar zona aquí"
    public static let description = IntentDescription("Guarda la pose actual tras confirmación humana.")
    public static let openAppWhenRun = true
    @Parameter(title: "Nombre de la zona") public var name: String

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let environment = PhoneHostEnvironment.shared
        try await GimbalIntentActionService.saveZone(
            name: name,
            runtime: environment.runtime,
            confirm: { draft in
                let yaw = draft.pose.yaw.formatted(.number.precision(.fractionLength(1)))
                let pitch = draft.pose.pitch.formatted(.number.precision(.fractionLength(1)))
                try await self.requestConfirmation(
                    result: .result(dialog: "¿Guardar \(draft.zone.name) en yaw \(yaw)° y pitch \(pitch)°?"),
                    confirmationActionName: .create,
                    showPrompt: true
                )
            }
        )
        return .result(dialog: "Zona guardada.")
    }
}

public struct GimbalShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LookAtZoneIntent(),
            phrases: ["Mira a \(\.$zone) con \(.applicationName)"],
            shortTitle: "Mirar a zona",
            systemImageName: "viewfinder"
        )
        AppShortcut(
            intent: StopGimbalIntent(),
            phrases: ["Para el estabilizador con \(.applicationName)"],
            shortTitle: "Parar",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: GimbalStatusIntent(),
            phrases: ["Estado del estabilizador con \(.applicationName)"],
            shortTitle: "Estado",
            systemImageName: "battery.100"
        )
        AppShortcut(
            intent: SaveZoneHereIntent(),
            phrases: ["Guarda esta zona con \(.applicationName)"],
            shortTitle: "Guardar zona",
            systemImageName: "mappin"
        )
    }
}
#endif
~~~

Esta es la implementación completa del módulo de intents iOS. requestConfirmation es async throws -> Void: no comparar su retorno con .confirmed. Los cuatro perform declaran ProvidesDialog; las propiedades estáticas almacenadas son let; las frases se construyen con applicationName. El diálogo de guardado se muestra después de preparar el draft, contiene la pose de ese draft y `confirmZone` recibe ese mismo valor.

- [ ] **Step 4: Comprobar módulo y tests**

~~~sh
CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter GimbalIntentActionServiceTests
CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift build --disable-sandbox --scratch-path .build
~~~

Expected: compilación macOS del servicio puro; pruebas de token antes de espera, parada inmediata, estado offline y cancelación sin escritura pasan. La firma iOS de App Intents se verifica con el build Xcode de Task 6.

---

### Task 4 — Protocolo portable GimbalWatchKit

**Files:**
- Modify: Package.swift
- Create: Sources/GimbalWatchKit/WatchMessages.swift, Tests/GimbalWatchKitTests/WatchMessagesTests.swift

**Interfaces:**
- Produces: WatchCommand (stop, look(zone:), status), WatchRequest(session:seq:operationID:stopToken:command:), WatchPose, WatchStatus con stopToken y terminalEvent, WatchEvent (arrived/stopped con stopCounter y rejected(reason:)), WatchRejection, WatchMessageCodec y WatchOperationState.
- GimbalWatchKit importa Foundation/CoreFoundation solamente y no depende de host support, Bluetooth, App Intents o WatchConnectivity.
- Añadir GimbalWatchKit como producto de biblioteca y target portables fuera de #if os(macOS). Añadir WatchMessagesTests a la lista de tests macOS existente. No incluir GimbalKit como dependencia: WatchPose es el DTO portable de yaw/pitch/roll.

- [ ] **Step 1: Probar codec, terminal recuperable y reducción de eventos**

Probar round-trip de cada comando, evento (incluidos `stopCounter` en arrived/stopped), pose y estado como diccionarios; el estado round-trips también `terminalEvent`. Malformados: tipo equivocado, claves extra, UUID inválido, seq/token/stopCounter negativos, decimal, Bool, NaN o infinito, look sin operationID o stopToken, arrived/stopped sin stopCounter, zona vacía, pose no finita y batería fuera de 0...100. Para comprobar finitud, pasar NSNumber(value: Double.nan) en pose; no añadir un campo de velocidad al protocolo. Probar que el reducer de presentación ignora operationID ajeno y limpia el actual en rechazo, incluso cuando no hay estado de época. La misma llegada procesada primero por sendMessage y después por application context se acepta una vez y no vuelve a producir cambio de `lastEvent` ni háptica.

Prueba focal completa para el terminal duplicado:

~~~swift
@Test func immediateAndContextTerminalUseTheSameReducerOnce() throws {
    let operationID = UUID()
    let sessionID = UUID()
    let event = WatchEvent.arrived(operationID: operationID, stopCounter: 4)
    let envelope = WatchEventEnvelope(session: sessionID, event: event)
    let status = WatchStatus(stopToken: 4, connected: true, batteryPercent: 80, pose: nil,
                             zoneNames: ["mesa"], terminalEvent: envelope)
    let recovered = try WatchMessageCodec.decodeStatus(WatchMessageCodec.encodeStatus(status))
    #expect(recovered == status)

    var reducer = WatchOperationState()
    reducer.begin(operationID)
    #expect(reducer.apply(event) == event)
    #expect(reducer.apply(try #require(recovered.terminalEvent).event) == nil)
    #expect(reducer.currentOperationID == nil)
}
~~~

- [ ] **Step 2: Implementar DTO y codec de objetos**

WatchMessages.swift completo. Los DTO son Codable aunque la frontera WatchConnectivity usa el codec de diccionarios objeto:

~~~swift
import CoreFoundation
import Foundation

public enum WatchCommand: Codable, Sendable, Equatable {
    case stop
    case look(zone: String)
    case status
}

public struct WatchRequest: Codable, Sendable, Equatable {
    public let session: UUID
    public let seq: UInt64
    public let operationID: UUID?
    public let stopToken: UInt64?
    public let command: WatchCommand

    public init(session: UUID, seq: UInt64, operationID: UUID?, stopToken: UInt64?, command: WatchCommand) {
        self.session = session
        self.seq = seq
        self.operationID = operationID
        self.stopToken = stopToken
        self.command = command
    }
}

public enum WatchRejection: String, Codable, Sendable, Equatable {
    case malformed, unsupportedVersion, outOfOrder, staleAfterStop
    case quietPeriod, busy, zoneNotFound, disconnected, referenceRequired
    case stalePose, unsafePath, timeout, interrupted, policyRejected, failed
}

public enum WatchEvent: Codable, Sendable, Equatable {
    case arrived(operationID: UUID, stopCounter: UInt64)
    case stopped(operationID: UUID, stopCounter: UInt64)
    case rejected(operationID: UUID, reason: WatchRejection)
}

public struct WatchEventEnvelope: Codable, Sendable, Equatable {
    public let session: UUID?
    public let event: WatchEvent

    public init(session: UUID?, event: WatchEvent) {
        self.session = session
        self.event = event
    }
}

public struct WatchPose: Codable, Sendable, Equatable {
    public let yaw: Double
    public let pitch: Double
    public let roll: Double

    public init(yaw: Double, pitch: Double, roll: Double) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }
}

public struct WatchStatus: Codable, Sendable, Equatable {
    public let stopToken: UInt64
    public let connected: Bool
    public let batteryPercent: Int?
    public let pose: WatchPose?
    public let zoneNames: [String]
    public let terminalEvent: WatchEventEnvelope?

    public init(stopToken: UInt64, connected: Bool, batteryPercent: Int?, pose: WatchPose?, zoneNames: [String], terminalEvent: WatchEventEnvelope? = nil) {
        self.stopToken = stopToken
        self.connected = connected
        self.batteryPercent = batteryPercent
        self.pose = pose
        self.zoneNames = zoneNames
        self.terminalEvent = terminalEvent
    }
}

public struct WatchOperationState: Sendable, Equatable {
    public private(set) var currentOperationID: UUID?

    public init() {}
    public mutating func begin(_ id: UUID) { currentOperationID = id }

    public mutating func apply(_ event: WatchEvent) -> WatchEvent? {
        let id: UUID
        switch event {
        case let .arrived(operationID, _), let .stopped(operationID, _):
            id = operationID
        case let .rejected(operationID, _):
            id = operationID
        }
        guard currentOperationID == id else { return nil }
        currentOperationID = nil
        return event
    }
}

public enum WatchMessageError: Error, Sendable, Equatable {
    case malformed, unsupportedVersion, invalidSequence, invalidSession
    case invalidOperationID, invalidZone, invalidStatus
}

public enum WatchMessageCodec {
    public static func encodeRequest(_ request: WatchRequest) -> [String: Any] {
        var result: [String: Any] = [
            "version": NSNumber(value: 1),
            "session": request.session.uuidString,
            "seq": NSNumber(value: request.seq)
        ]
        switch request.command {
        case .stop:
            result["command"] = "stop"
            if let operationID = request.operationID { result["operationID"] = operationID.uuidString }
        case let .look(zone):
            result["command"] = "look"
            result["zone"] = zone
            if let operationID = request.operationID { result["operationID"] = operationID.uuidString }
            if let stopToken = request.stopToken { result["stopToken"] = NSNumber(value: stopToken) }
        case .status:
            result["command"] = "status"
        }
        return result
    }

    public static func decodeRequest(_ values: [String: Any]) throws -> WatchRequest {
        guard let version = unsigned(values["version"]), version == 1 else {
            throw WatchMessageError.unsupportedVersion
        }
        guard let sessionText = values["session"] as? String, let session = UUID(uuidString: sessionText) else {
            throw WatchMessageError.invalidSession
        }
        guard let seq = unsigned(values["seq"]) else { throw WatchMessageError.invalidSequence }
        guard let command = values["command"] as? String else { throw WatchMessageError.malformed }

        switch command {
        case "stop":
            guard Set(values.keys) == ["version", "session", "seq", "command", "operationID"],
                  let id = uuid(values["operationID"]) else { throw WatchMessageError.invalidOperationID }
            return WatchRequest(session: session, seq: seq, operationID: id, stopToken: nil, command: .stop)
        case "look":
            guard Set(values.keys) == ["version", "session", "seq", "command", "zone", "operationID", "stopToken"],
                  let id = uuid(values["operationID"]) else { throw WatchMessageError.invalidOperationID }
            guard let stopToken = unsigned(values["stopToken"]) else { throw WatchMessageError.invalidSequence }
            guard let zone = values["zone"] as? String,
                  !zone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WatchMessageError.invalidZone
            }
            return WatchRequest(session: session, seq: seq, operationID: id, stopToken: stopToken, command: .look(zone: zone))
        case "status":
            guard Set(values.keys) == ["version", "session", "seq", "command"] else {
                throw WatchMessageError.malformed
            }
            return WatchRequest(session: session, seq: seq, operationID: nil, stopToken: nil, command: .status)
        default:
            throw WatchMessageError.malformed
        }
    }

    public static func encodeEvent(_ envelope: WatchEventEnvelope) -> [String: Any] {
        var result: [String: Any] = ["version": NSNumber(value: 1)]
        if let session = envelope.session { result["session"] = session.uuidString }
        switch envelope.event {
        case let .arrived(id, stopCounter):
            result["event"] = "arrived"
            result["operationID"] = id.uuidString
            result["stopCounter"] = NSNumber(value: stopCounter)
        case let .stopped(id, stopCounter):
            result["event"] = "stopped"
            result["operationID"] = id.uuidString
            result["stopCounter"] = NSNumber(value: stopCounter)
        case let .rejected(id, reason):
            result["event"] = "rejected"
            result["operationID"] = id.uuidString
            result["reason"] = reason.rawValue
        }
        return result
    }

    public static func decodeEvent(_ values: [String: Any]) throws -> WatchEventEnvelope {
        guard let version = unsigned(values["version"]), version == 1 else {
            throw WatchMessageError.unsupportedVersion
        }
        let session = (values["session"] as? String).flatMap(UUID.init(uuidString:))
        guard values["session"] == nil || session != nil,
              let kind = values["event"] as? String,
              let id = uuid(values["operationID"]) else { throw WatchMessageError.malformed }
        let event: WatchEvent
        switch kind {
        case "arrived":
            guard let stopCounter = unsigned(values["stopCounter"]),
                  Set(values.keys) == ["version", "event", "operationID", "stopCounter"] ||
                  Set(values.keys) == ["version", "session", "event", "operationID", "stopCounter"] else {
                throw WatchMessageError.malformed
            }
            event = .arrived(operationID: id, stopCounter: stopCounter)
        case "stopped":
            guard let stopCounter = unsigned(values["stopCounter"]),
                  Set(values.keys) == ["version", "event", "operationID", "stopCounter"] ||
                  Set(values.keys) == ["version", "session", "event", "operationID", "stopCounter"] else {
                throw WatchMessageError.malformed
            }
            event = .stopped(operationID: id, stopCounter: stopCounter)
        case "rejected":
            guard let raw = values["reason"] as? String,
                  let reason = WatchRejection(rawValue: raw),
                  Set(values.keys) == ["version", "event", "operationID", "reason"] ||
                  Set(values.keys) == ["version", "session", "event", "operationID", "reason"] else {
                throw WatchMessageError.malformed
            }
            event = .rejected(operationID: id, reason: reason)
        default:
            throw WatchMessageError.malformed
        }
        return WatchEventEnvelope(session: session, event: event)
    }

    public static func encodeStatus(_ status: WatchStatus) -> [String: Any] {
        var result: [String: Any] = [
            "version": NSNumber(value: 1),
            "kind": "status",
            "stopToken": NSNumber(value: status.stopToken),
            "connected": NSNumber(value: status.connected),
            "zones": status.zoneNames
        ]
        if let battery = status.batteryPercent { result["batteryPercent"] = NSNumber(value: battery) }
        if let pose = status.pose {
            result["pose"] = [
                "yaw": NSNumber(value: pose.yaw),
                "pitch": NSNumber(value: pose.pitch),
                "roll": NSNumber(value: pose.roll)
            ]
        }
        if let terminalEvent = status.terminalEvent {
            result["terminalEvent"] = encodeEvent(terminalEvent)
        }
        return result
    }

    public static func decodeStatus(_ values: [String: Any]) throws -> WatchStatus {
        guard unsigned(values["version"]) == 1,
              values["kind"] as? String == "status",
              let stopToken = unsigned(values["stopToken"]),
              let connected = values["connected"] as? NSNumber,
              CFGetTypeID(connected) == CFBooleanGetTypeID(),
              let zones = values["zones"] as? [String],
              zones.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(values.keys).isSubset(of: Set(["version", "kind", "stopToken", "connected", "zones", "batteryPercent", "pose", "terminalEvent"])),
              Set(["version", "kind", "stopToken", "connected", "zones"]).isSubset(of: Set(values.keys)) else {
            throw WatchMessageError.invalidStatus
        }
        let battery: Int?
        if let raw = values["batteryPercent"] {
            guard let integer = unsigned(raw), integer <= 100 else { throw WatchMessageError.invalidStatus }
            battery = Int(integer)
        } else {
            battery = nil
        }
        let pose: WatchPose?
        if let raw = values["pose"] {
            guard let angles = raw as? [String: Any], Set(angles.keys) == ["yaw", "pitch", "roll"],
                  let yaw = finite(angles["yaw"]), let pitch = finite(angles["pitch"]),
                  let roll = finite(angles["roll"]) else { throw WatchMessageError.invalidStatus }
            pose = WatchPose(yaw: yaw, pitch: pitch, roll: roll)
        } else {
            pose = nil
        }
        let terminalEvent: WatchEventEnvelope?
        if let raw = values["terminalEvent"] {
            guard let object = raw as? [String: Any] else { throw WatchMessageError.invalidStatus }
            terminalEvent = try decodeEvent(object)
        } else {
            terminalEvent = nil
        }
        return WatchStatus(stopToken: stopToken, connected: connected.boolValue, batteryPercent: battery,
                           pose: pose, zoneNames: zones, terminalEvent: terminalEvent)
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let text = value as? String else { return nil }
        return UUID(uuidString: text)
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }

    private static func finite(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
~~~


- [ ] **Step 3: Ejecutar tests portables**

~~~sh
CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter WatchMessagesTests
CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift build --disable-sandbox --scratch-path .build
~~~

Expected: round-trip y rechazos tipados; ninguna prueba abre una sesión WatchConnectivity ni sockets.

---

### Task 5 — PhoneWatchService: secuencias, STOP prioritario y silencio

**Files:**
- Modify: Package.swift
- Create: Sources/GimbalHostSupport/PhoneWatchService.swift, Tests/GimbalHostSupportTests/PhoneWatchServiceTests.swift

**Interfaces:**
- Consumes: HostRuntime, MotionStopCounter, RuntimeClock, WatchRequest, WatchEvent, WatchStatus, WatchRejection.
- Produces: PhoneWatchService.init(runtime:clock:); receive(_:) async; setReachable(_:) async; startObservingStopCounter(); refreshStatus(); outputs: AsyncStream<PhoneWatchOutput>; synchronous stopCounter for publication checks.
- Se añade GimbalWatchKit como dependencia de GimbalHostSupport. El reloj real usa .live; tests usan StepSleeper existente o instancia propia con nombre único.
- En Package.swift, añadir GimbalWatchKit a las dependencias del target GimbalHostSupport y del testTarget GimbalHostSupportTests; no mover ni ampliar ningún otro target de tests.

- [ ] **Step 1: Escribir pruebas de las carreras antes de la implementación**

Usar un FakePhoneWatchRuntime actor con continuaciones para bloquear look antes de devolver. Probar: secuencia 1 aceptada, duplicada y fuera de orden rechazada; el caso exacto `look seq=1`, `status seq=3`, `stop seq=2` en ese orden de entrega incrementa el counter y ejecuta humanStop aunque `seq=2` sea menor que el máximo visto; el máximo y la barrera nunca retroceden; seq anterior al STOP rechazado; segundo look recibe .busy; nombre no configurado da .zoneNotFound; error de referencia/seguridad se conserva en rejected(reason:); dos segundos después de STOP se acepta look; antes se rechaza .quietPeriod.

En la barrera de actor, detener entre la admisión del servicio y la entrada al look fake: el fake debe observar el token ya obsoleto y no aceptar movimiento. Probar la ruta real con HostRuntime aparte para demostrar que su primera guardia aborta un token antiguo sin lease ni escritura.

Bloquear look durante la preparación, llamar setReachable(false) y verificar que el contador aumenta y humanStop entra antes de liberar la continuación. Tras liberar, esperar señal de terminación del productor antes de comprobar que no se publicó .arrived. Hacer que termine una operación vieja después de iniciar otra y comprobar que no borra el operationID nuevo.

Incrementar el contador mediante STOP del runtime (iPhone/Atajos), avanzar el reloj controlado y comprobar silencio y evento stopped para la operación vigente. Verificar que el observer no vuelve a llamar humanStop por un incremento que él mismo acaba de observar.

Añadir una prueba de reachability que detiene el look, recupera alcance antes de 2 s y recibe un look nuevo sin ejecutar el observer entre medias: debe seguir en `.quietPeriod`, porque `setReachable(false)` escribió quietUntil antes del await. Forzar una llegada obsoleta encolándola con el token de la operación, incrementar el counter antes de publicarla y aplicar `PhoneWatchEventPublication.decision`: no puede salir `arrived`; produce `stopped` para el mismo operationID y actualiza el resultado terminal del contexto. Probar también que un `stopped` obsoleto no se envía como resultado inmediato. Cambiar las zonas del fake tras un guardado externo, pedir status y después mirar esa zona sin llamar ningún setter desde UI; debe aparecer y admitirse. Verificar que un evento terminal aparece en application context y que el reducer procesa una copia inmediata y otra de contexto una sola vez.

Fixture y pruebas completas para STOP desordenado, silencio inmediato tras perder alcance y caché de zonas obtenida del runtime:

~~~swift
private actor FakePhoneWatchRuntime: PhoneWatchRuntime {
    nonisolated let motionStopCounter = MotionStopCounter()
    private var savedZones: [ZoneRecord]
    private var pendingLook: CheckedContinuation<GimbalLookResult, any Error>?
    private(set) var lookCalls = 0
    private(set) var stopCalls = 0

    init(zones: [ZoneRecord] = [ZoneRecord(Zone(name: "mesa", yaw: -10...10, pitch: -10...10))]) {
        savedZones = zones
    }

    func look(zone: String, leaseSeconds: Double, stopToken: UInt64?) async throws -> GimbalLookResult {
        if let stopToken, motionStopCounter.read() != stopToken { throw NavigationError.interrupted }
        lookCalls += 1
        return try await withCheckedThrowingContinuation { pendingLook = $0 }
    }

    func completeLook() {
        pendingLook?.resume(returning: GimbalLookResult(
            status: GimbalStatus(connected: true, referenceReady: true,
                                 battery: BatteryStatus(percent: 80, charging: false), pose: Pose(), lease: nil),
            arrivalPose: Pose()
        ))
        pendingLook = nil
    }

    func humanStop() async {
        motionStopCounter.increment()
        stopCalls += 1
    }

    func status() async throws -> GimbalStatus {
        GimbalStatus(connected: true, referenceReady: true,
                     battery: BatteryStatus(percent: 80, charging: false), pose: Pose(), lease: nil)
    }

    func zones() async -> [ZoneRecord] { savedZones }
    func replaceZones(_ zones: [ZoneRecord]) { savedZones = zones }
}

private actor PhoneWatchOutputLog {
    private var values: [PhoneWatchOutput] = []
    func append(_ value: PhoneWatchOutput) { values.append(value) }
    func contains(_ event: WatchEvent) -> Bool {
        values.contains { value in
            guard case let .event(envelope) = value else { return false }
            return envelope.event == event
        }
    }
    func containsStatusZones(_ names: [String]) -> Bool {
        values.contains { value in
            guard case let .status(status) = value else { return false }
            return status.zoneNames == names
        }
    }
}

@Test func outOfOrderStopStillStopsAfterNewerStatus() async {
    let runtime = FakePhoneWatchRuntime()
    let service = PhoneWatchService(runtime: runtime)
    let session = UUID()
    await service.refreshStatus()
    let look = Task {
        await service.receive(WatchRequest(session: session, seq: 1, operationID: UUID(),
                                           stopToken: 0, command: .look(zone: "mesa")))
    }
    #expect(await eventually { await runtime.lookCalls == 1 })
    await service.receive(WatchRequest(session: session, seq: 3, operationID: nil,
                                       stopToken: nil, command: .status))
    await service.receive(WatchRequest(session: session, seq: 2, operationID: UUID(),
                                       stopToken: nil, command: .stop))
    #expect(await runtime.stopCalls == 1)
    #expect(runtime.motionStopCounter.read() == 1)
    await runtime.completeLook()
    await look.value
    #expect(await runtime.lookCalls == 1)
    await service.shutdown()
}

@Test func reachabilityLossOpensQuietPeriodBeforeObserverRuns() async {
    let runtime = FakePhoneWatchRuntime()
    let service = PhoneWatchService(runtime: runtime)
    let log = PhoneWatchOutputLog()
    let collector = Task {
        for await value in service.outputs { await log.append(value) }
    }
    let session = UUID()
    await service.refreshStatus()
    let first = Task {
        await service.receive(WatchRequest(session: session, seq: 1, operationID: UUID(),
                                           stopToken: 0, command: .look(zone: "mesa")))
    }
    #expect(await eventually { await runtime.lookCalls == 1 })
    await service.setReachable(false)
    await service.setReachable(true)
    let retryID = UUID()
    await service.receive(WatchRequest(session: session, seq: 2, operationID: retryID,
                                       stopToken: 1, command: .look(zone: "mesa")))
    #expect(await eventually {
        await log.contains(.rejected(operationID: retryID, reason: .quietPeriod))
    })
    #expect(await runtime.lookCalls == 1)
    await runtime.completeLook()
    await first.value
    await service.shutdown()
    await collector.value
}

@Test func statusRefreshLoadsZonesUsedForAdmissionWithoutViewSetter() async {
    let runtime = FakePhoneWatchRuntime()
    let service = PhoneWatchService(runtime: runtime)
    let log = PhoneWatchOutputLog()
    let collector = Task {
        for await value in service.outputs { await log.append(value) }
    }
    let newZone = ZoneRecord(Zone(name: "salon", yaw: 20...40, pitch: -10...10))
    await runtime.replaceZones([newZone])
    await service.refreshStatus()
    #expect(await log.containsStatusZones(["salon"]))
    let session = UUID()
    let looking = Task {
        await service.receive(WatchRequest(session: session, seq: 1, operationID: UUID(),
                                           stopToken: 0, command: .look(zone: "salon")))
    }
    #expect(await eventually { await runtime.lookCalls == 1 })
    await runtime.completeLook()
    await looking.value
    await service.shutdown()
    await collector.value
}
~~~

Prueba focal completa de la decisión de publicación, que el bridge usa en el momento de enviar:

~~~swift
@Test func staleArrivalBecomesStoppedAndStaleStoppedIsDropped() {
    let sessionID = UUID()
    let operationID = UUID()
    let staleArrival = WatchEventEnvelope(
        session: sessionID,
        event: .arrived(operationID: operationID, stopCounter: 4)
    )
    let correction = WatchEventEnvelope(
        session: sessionID,
        event: .stopped(operationID: operationID, stopCounter: 4)
    )
    #expect(PhoneWatchEventPublication.decision(for: staleArrival, currentStopCounter: 5) == .correctStaleArrival(correction))
    #expect(PhoneWatchEventPublication.decision(for: correction, currentStopCounter: 5) == .discard)
    #expect(PhoneWatchEventPublication.decision(for: correction, currentStopCounter: 4) == .send(correction))
}
~~~

- [ ] **Step 2: Implementar admisión síncrona y operación con identidad**

PhoneWatchService.swift contiene el estado aislado y el algoritmo completo. El test fake implementa el mismo protocolo que HostRuntime:

~~~swift
import Foundation
import GimbalKit
import GimbalKitMCP
import GimbalWatchKit

public protocol PhoneWatchRuntime: Sendable {
    var motionStopCounter: MotionStopCounter { get }
    func look(zone: String, leaseSeconds: Double, stopToken: UInt64?) async throws -> GimbalLookResult
    func humanStop() async
    func status() async throws -> GimbalStatus
    func zones() async -> [ZoneRecord]
}

extension HostRuntime: PhoneWatchRuntime {}

public enum PhoneWatchOutput: Sendable, Equatable {
    case event(WatchEventEnvelope)
    case status(WatchStatus)
}

public enum PhoneWatchEventPublication: Sendable, Equatable {
    case send(WatchEventEnvelope)
    case discard
    case correctStaleArrival(WatchEventEnvelope)

    public static func decision(for envelope: WatchEventEnvelope, currentStopCounter: UInt64) -> Self {
        switch envelope.event {
        case let .arrived(id, token) where token != currentStopCounter:
            return .correctStaleArrival(WatchEventEnvelope(
                session: envelope.session,
                event: .stopped(operationID: id, stopCounter: token)
            ))
        case let .stopped(_, token) where token != currentStopCounter:
            return .discard
        default:
            return .send(envelope)
        }
    }
}

public actor PhoneWatchService {
    private struct Operation: Sendable, Equatable {
        let session: UUID
        let seq: UInt64
        let id: UUID
        let token: UInt64
    }

    public nonisolated let outputs: AsyncStream<PhoneWatchOutput>
    public nonisolated let stopCounter: MotionStopCounter
    private let output: AsyncStream<PhoneWatchOutput>.Continuation
    private let runtime: any PhoneWatchRuntime
    private let clock: RuntimeClock
    private var lastSequenceBySession: [UUID: UInt64] = [:]
    private var stopSequenceBySession: [UUID: UInt64] = [:]
    private var zoneNames = Set<String>()
    private var latestTerminalEvent: WatchEventEnvelope?
    private var active: Operation?
    private var reachable = true
    private var quietUntil: Date?
    private var observedStopCounter: UInt64
    private var observer: Task<Void, Never>?

    public init(runtime: any PhoneWatchRuntime, clock: RuntimeClock = .live) {
        let pair = AsyncStream.makeStream(of: PhoneWatchOutput.self)
        self.outputs = pair.stream
        self.stopCounter = runtime.motionStopCounter
        self.output = pair.continuation
        self.runtime = runtime
        self.clock = clock
        self.observedStopCounter = runtime.motionStopCounter.read()
    }

    public var watchOperationActive: Bool { active != nil }

    public func startObservingStopCounter() {
        guard observer == nil else { return }
        let clock = self.clock
        observer = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(0.025) } catch { return }
                await self?.observeExternalStop()
            }
        }
    }

    public func shutdown() {
        observer?.cancel()
        observer = nil
        output.finish()
    }

    public func receive(_ request: WatchRequest) async {
        observeCounterChange()
        if case .stop = request.command {
            await stop(request)
            return
        }
        if case .look(_) = request.command,
           let stopSeq = stopSequenceBySession[request.session], request.seq <= stopSeq {
            reject(session: request.session, id: request.operationID ?? UUID(), reason: .staleAfterStop)
            return
        }
        guard acceptSequence(request) else { return }

        switch request.command {
        case let .look(zone):
            await look(zone: zone, request: request)
        case .status:
            await sendStatus()
        case .stop:
            return
        }
    }

    public func rejectMalformed(session: UUID?, operationID: UUID?) {
        reject(session: session, id: operationID ?? UUID(), reason: .malformed)
    }

    public func refreshStatus() async {
        await sendStatus()
    }

    public func replaceLatestTerminalEvent(_ envelope: WatchEventEnvelope) {
        latestTerminalEvent = envelope
    }

    public func setReachable(_ isReachable: Bool) async {
        observeCounterChange()
        reachable = isReachable
        guard !isReachable, let operation = active else { return }
        quietUntil = clock.now().addingTimeInterval(2)
        active = nil
        await runtime.humanStop()
        observedStopCounter = runtime.motionStopCounter.read()
        emit(WatchEventEnvelope(
            session: operation.session,
            event: .stopped(operationID: operation.id, stopCounter: operation.token)
        ))
    }

    private func acceptSequence(_ request: WatchRequest) -> Bool {
        if let previous = lastSequenceBySession[request.session], request.seq <= previous {
            reject(session: request.session, id: request.operationID ?? UUID(), reason: .outOfOrder)
            return false
        }
        lastSequenceBySession[request.session] = request.seq
        return true
    }

    private func stop(_ request: WatchRequest) async {
        let stopID = request.operationID ?? UUID()
        quietUntil = clock.now().addingTimeInterval(2)
        let old = active
        active = nil
        if lastSequenceBySession[request.session].map({ request.seq > $0 }) ?? true {
            lastSequenceBySession[request.session] = request.seq
        }
        if stopSequenceBySession[request.session].map({ request.seq > $0 }) ?? true {
            stopSequenceBySession[request.session] = request.seq
        }
        await runtime.humanStop()
        observedStopCounter = runtime.motionStopCounter.read()
        if let old {
            emit(WatchEventEnvelope(
                session: old.session,
                event: .stopped(operationID: old.id, stopCounter: old.token)
            ))
        }
        emit(WatchEventEnvelope(
            session: request.session,
            event: .stopped(operationID: stopID, stopCounter: observedStopCounter)
        ))
    }

    private func look(zone: String, request: WatchRequest) async {
        guard let id = request.operationID else {
            reject(session: request.session, id: UUID(), reason: .malformed)
            return
        }
        if let quietUntil, clock.now() < quietUntil {
            reject(session: request.session, id: id, reason: .quietPeriod)
            return
        }
        guard reachable else {
            reject(session: request.session, id: id, reason: .disconnected)
            return
        }
        guard zoneNames.contains(zone) else {
            reject(session: request.session, id: id, reason: .zoneNotFound)
            return
        }
        guard active == nil else {
            reject(session: request.session, id: id, reason: .busy)
            return
        }

        let token = runtime.motionStopCounter.read()
        guard request.stopToken == token else {
            reject(session: request.session, id: id, reason: .staleAfterStop)
            return
        }
        let operation = Operation(session: request.session, seq: request.seq, id: id, token: token)
        active = operation

        do {
            _ = try await runtime.look(zone: zone, leaseSeconds: 30, stopToken: token)
            observeCounterChange()
            guard active == operation, runtime.motionStopCounter.read() == token else { return }
            active = nil
            emit(WatchEventEnvelope(
                session: request.session,
                event: .arrived(operationID: id, stopCounter: operation.token)
            ))
        } catch {
            observeCounterChange()
            guard active == operation, runtime.motionStopCounter.read() == token else { return }
            active = nil
            reject(session: request.session, id: id, reason: rejection(for: error))
        }
    }

    private func sendStatus() async {
        let records = await runtime.zones()
        let zones = records.filter { !$0.forbidden }.map(\.name).sorted()
        zoneNames = Set(zones)
        do {
            let status = try await runtime.status()
            output.yield(.status(WatchStatus(
                stopToken: runtime.motionStopCounter.read(),
                connected: status.connected,
                batteryPercent: status.battery?.percent,
                pose: status.pose.map { WatchPose(yaw: $0.yaw, pitch: $0.pitch, roll: $0.roll) },
                zoneNames: zones,
                terminalEvent: latestTerminalEvent
            )))
        } catch {
            output.yield(.status(WatchStatus(
                stopToken: runtime.motionStopCounter.read(),
                connected: false, batteryPercent: nil, pose: nil, zoneNames: zones,
                terminalEvent: latestTerminalEvent
            )))
        }
    }

    private func observeExternalStop() {
        observeCounterChange()
    }

    private func observeCounterChange() {
        let current = runtime.motionStopCounter.read()
        guard current != observedStopCounter else { return }
        observedStopCounter = current
        quietUntil = clock.now().addingTimeInterval(2)
        guard let old = active else { return }
        active = nil
        emit(WatchEventEnvelope(
            session: old.session,
            event: .stopped(operationID: old.id, stopCounter: old.token)
        ))
    }

    private func reject(session: UUID?, id: UUID, reason: WatchRejection) {
        emit(WatchEventEnvelope(
            session: session,
            event: .rejected(operationID: id, reason: reason)
        ))
    }

    private func emit(_ envelope: WatchEventEnvelope) {
        latestTerminalEvent = envelope
        output.yield(.event(envelope))
    }

    private func rejection(for error: any Error) -> WatchRejection {
        if let error = error as? NavigationError {
            switch error {
            case .busy: return .busy
            case .referenceRequired: return .referenceRequired
            case .stalePose: return .stalePose
            case .unsafePath: return .unsafePath
            case .timeout: return .timeout
            case .interrupted: return .interrupted
            }
        }
        if let error = error as? SafetyViolation {
            switch error {
            case .unknownZone(_): return .zoneNotFound
            case .poseUnavailable: return .disconnected
            case .busy(_): return .busy
            case .speedTooHigh(_, _), .forbiddenZone(_), .outsideZone(_), .invalidValue: return .policyRejected
            case .noLease, .leaseExpired, .leaseTooLong(_), .invalidDuration, .unsupported(_): return .failed
            }
        }
        return .failed
    }
}
~~~

receive despacha STOP antes de aplicar staleAfterStop o acceptSequence; no lo rechaza por ser duplicado o tener seq menor. quietUntil y la operación activa se actualizan sincrónicamente y los máximos/barrera solo avanzan si seq es mayor, antes de esperar a runtime.humanStop. En look, toda validación, lectura del counter y reserva de active ocurre sin suspensión; la llamada a runtime.look es la primera operación que puede suspender. Las terminaciones comparan counter e identidad después del await. setReachable(false) fija quietUntil y limpia active antes de invocar humanStop; el counter observer no vuelve a parar el runtime, solo abre silencio y descarta una terminación obsoleta.

sendStatus consulta las zonas actuales del runtime y actualiza la caché de admisión antes de suspenderse para leer status; no depende de PhoneHomeView ni de `setZones`. Cada evento terminal queda en `latestTerminalEvent`, se incluye en status y el puente puede sustituir una llegada obsoleta por stopped. Al recibir un diccionario que el codec no puede decodificar, el bridge llama rejectMalformed con los UUID que sí pudo recuperar; siempre rechaza sin movimiento.

- [ ] **Step 3: Verificar pruebas de servicio**

~~~sh
CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter PhoneWatchServiceTests
~~~

Expected: carreras de STOP ordenado/desordenado, token entre actores, silencio después de pérdida de alcance sin observer, llegada obsoleta entre cola y envío, recuperación terminal por contexto, actualización de zonas sin UI, reachability durante preparación, secuencia, busy, operación tardía y razones reales pasan con reloj/continuaciones controlados.

---

### Task 6 — Proyecto XcodeGen, app iPhone y app Watch

**Files:**
- Create: Apps/project.yml, Apps/GimbalPhone/GimbalPhoneApp.swift, Apps/GimbalPhone/PhoneHomeView.swift, Apps/GimbalPhone/PhoneWatchBridge.swift, Apps/GimbalWatch/GimbalWatchApp.swift, Apps/GimbalWatch/WatchHomeView.swift, Apps/GimbalWatch/WatchConnectivityClient.swift

**Interfaces:**
- iPhone importa productos locales GimbalKit, GimbalKitDJI, GimbalKitBLE, GimbalHostSupport, GimbalKitIntents y GimbalWatchKit.
- Watch importa GimbalWatchKit y WatchConnectivity; no enlaza BLE, MCP ni GimbalHostSupport.
- Targets: GimbalPhone iOS 17; GimbalWatch watchOS 10, bundle id dev.gimbalkit.phone.watchkitapp, companion dev.gimbalkit.phone.
- El puente es el único dueño de WCSession por app. PhoneWatchService queda en GimbalHostSupport; el target Watch solo mantiene presentación y sesión.

- [ ] **Step 1: Declarar los targets e info.properties completos**

Apps/project.yml:

~~~yaml
name: GimbalKitApps
options:
  createIntermediateGroups: true
packages:
  GimbalKit:
    path: ..
targets:
  GimbalWatch:
    type: application
    platform: watchOS
    deploymentTarget: "10.0"
    sources:
      - path: GimbalWatch
        excludes:
          - Info.plist
    info:
      path: GimbalWatch/Info.plist
      properties:
        CFBundleDisplayName: GimbalKit Watch
        WKApplication: true
        WKCompanionAppBundleIdentifier: dev.gimbalkit.phone
    dependencies:
      - package: GimbalKit
        product: GimbalWatchKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.gimbalkit.phone.watchkitapp
        SWIFT_VERSION: "6.0"
        WATCHOS_DEPLOYMENT_TARGET: "10.0"
        TARGETED_DEVICE_FAMILY: "4"
        SWIFT_STRICT_CONCURRENCY: complete
        CODE_SIGNING_ALLOWED: "NO"
  GimbalPhone:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: GimbalPhone
        excludes:
          - Info.plist
    info:
      path: GimbalPhone/Info.plist
      properties:
        CFBundleDisplayName: GimbalKit
        NSBluetoothAlwaysUsageDescription: GimbalKit usa Bluetooth para conectar con tu Osmo Mobile.
        UIBackgroundModes:
          - bluetooth-central
        UILaunchScreen: {}
    dependencies:
      - package: GimbalKit
        product: GimbalKit
      - package: GimbalKit
        product: GimbalKitDJI
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
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.gimbalkit.phone
        SWIFT_VERSION: "6.0"
        IPHONEOS_DEPLOYMENT_TARGET: "17.0"
        TARGETED_DEVICE_FAMILY: "1,2"
        SWIFT_STRICT_CONCURRENCY: complete
        CODE_SIGNING_ALLOWED: "NO"
~~~

La sección final de productos y targets de Package.swift queda así; las líneas existentes de GimbalKit, GimbalKitSim, GimbalKitDJI, GimbalKitBLE, GimbalLabSupport, CLI, MCP, HostMac y LabMac se conservan:

~~~swift
var products: [Product] = [
    .library(name: "GimbalKit", targets: ["GimbalKit"]),
    .library(name: "GimbalKitSim", targets: ["GimbalKitSim"]),
    .library(name: "GimbalKitDJI", targets: ["GimbalKitDJI"]),
    .library(name: "GimbalKitBLE", targets: ["GimbalKitBLE"]),
    .library(name: "GimbalLabSupport", targets: ["GimbalLabSupport"]),
    .library(name: "GimbalWatchKit", targets: ["GimbalWatchKit"]),
]
var targets: [Target] = [
    .target(name: "GimbalKit"),
    .target(name: "GimbalKitSim", dependencies: ["GimbalKit"]),
    .target(name: "GimbalKitDJI", dependencies: ["GimbalKit"]),
    .target(name: "GimbalKitBLE", dependencies: ["GimbalKitDJI"]),
    .target(name: "GimbalLabSupport", dependencies: ["GimbalKit", "GimbalKitDJI"]),
    .target(name: "GimbalWatchKit"),
    .testTarget(name: "GimbalKitTests", dependencies: ["GimbalKit", "GimbalKitSim"]),
    .testTarget(name: "GimbalKitDJITests", dependencies: ["GimbalKitDJI", "GimbalKit", "GimbalKitSim", "GimbalLabSupport"]),
]
#if os(macOS)
products += [
    .library(name: "GimbalKitMCP", targets: ["GimbalKitMCP"]),
    .library(name: "GimbalHostSupport", targets: ["GimbalHostSupport"]),
    .library(name: "GimbalKitIntents", targets: ["GimbalKitIntents"]),
    .executable(name: "gimbal", targets: ["GimbalCLI"]),
    .executable(name: "GimbalHostMac", targets: ["GimbalHostMac"]),
    .executable(name: "GimbalLabMac", targets: ["GimbalLabMac"]),
]
targets += [
    .target(name: "GimbalKitMCP", dependencies: ["GimbalKit"]),
    .target(name: "GimbalHostSupport", dependencies: ["GimbalKit", "GimbalKitDJI", "GimbalKitMCP", "GimbalKitBLE", "GimbalWatchKit"]),
    .target(name: "GimbalKitIntents", dependencies: ["GimbalKit", "GimbalKitMCP", "GimbalHostSupport"]),
    .executableTarget(name: "GimbalCLI", dependencies: ["GimbalKitMCP"]),
    .executableTarget(name: "GimbalHostMac", dependencies: ["GimbalHostSupport", "GimbalKit", "GimbalKitBLE", "GimbalKitDJI", "GimbalKitMCP"]),
    .executableTarget(name: "GimbalLabMac", dependencies: ["GimbalLabSupport", "GimbalHostSupport", "GimbalKit", "GimbalKitBLE", "GimbalKitDJI"]),
    .executableTarget(name: "GimbalSmoke", dependencies: ["GimbalKitBLE", "GimbalKitDJI", "GimbalKit"]),
    .testTarget(name: "GimbalKitMCPTests", dependencies: ["GimbalKitMCP", "GimbalKit"]),
    .testTarget(name: "GimbalHostSupportTests", dependencies: ["GimbalHostSupport", "GimbalKit", "GimbalKitDJI", "GimbalKitMCP", "GimbalKitSim", "GimbalWatchKit"]),
    .testTarget(name: "GimbalKitIntentsTests", dependencies: ["GimbalKitIntents", "GimbalHostSupport", "GimbalKit", "GimbalKitMCP"]),
    .testTarget(name: "GimbalWatchKitTests", dependencies: ["GimbalWatchKit"]),
]
#endif
~~~

En la declaración existente de Package, añadir `.watchOS(.v10)` a platforms junto a `.macOS(.v14)` e `.iOS(.v17)`. GimbalWatchKit queda fuera del condicional por sistema anfitrión; GimbalKitIntents permanece dentro de #if os(macOS), que es donde XcodeGen evalúa este manifest y resuelve el producto para iOS. No crear un target MCP para iOS.

`info.path` es la ruta de salida del plist generado, no una plantilla. Las claves necesarias se declaran en `info.properties`; no crear ni confiar en contenido manual de `Apps/GimbalPhone/Info.plist` o `Apps/GimbalWatch/Info.plist`.

- [ ] **Step 2: Crear el arranque iPhone y su vista completa**

Apps/GimbalPhone/GimbalPhoneApp.swift:

~~~swift
import AppIntents
import GimbalHostSupport
import GimbalKitIntents
import GimbalWatchKit
import SwiftUI

@main
@MainActor
struct GimbalPhoneApp: App, AppIntentsPackage {
    nonisolated static var includedPackages: [any AppIntentsPackage.Type] {
        [GimbalKitIntentsPackage.self]
    }

    @State private var model: PhoneHostModel
    @State private var watchBridge: PhoneWatchBridge

    init() {
        let environment = PhoneHostEnvironment.shared
        let model = PhoneHostModel(environment: environment)
        let service = PhoneWatchService(runtime: environment.runtime)
        let bridge = PhoneWatchBridge(service: service)
        _model = State(initialValue: model)
        _watchBridge = State(initialValue: bridge)
        Task { @MainActor [model, service, bridge] in
            bridge.activate()
            await service.startObservingStopCounter()
            await model.start()
            await bridge.refreshStatus()
        }
    }

    var body: some Scene {
        WindowGroup {
            PhoneHomeView(model: model)
        }
    }
}
~~~

Apps/GimbalPhone/PhoneHomeView.swift:

~~~swift
import Observation
import GimbalHostSupport
import GimbalKit
import SwiftUI

@MainActor
struct PhoneHomeView: View {
    @Bindable var model: PhoneHostModel
    @State private var zoneName = ""
    @State private var forbidden = false
    @State private var zoneConfirmationDraft: ZoneDraft?
    @State private var showZoneConfirmation = false
    @State private var showReferenceConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("Estabilizador") {
                    Label(model.status.connected ? "Conectada" : "Desconectada · reconectando",
                          systemImage: model.status.connected ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                    if let battery = model.status.battery {
                        Text("Batería: \(battery.percent)%\(battery.charging ? " · cargando" : "")")
                    }
                    if let pose = model.status.pose {
                        Text("Yaw \(pose.yaw.formatted(.number.precision(.fractionLength(1))))° · Pitch \(pose.pitch.formatted(.number.precision(.fractionLength(1))))° · Roll \(pose.roll.formatted(.number.precision(.fractionLength(1))))°")
                    } else {
                        Text("Pose no disponible o desactualizada")
                    }
                    if let lease = model.status.lease {
                        Label("Agente con control de \(lease.zone)", systemImage: "eye.fill")
                            .foregroundStyle(.orange)
                    }
                    Button(role: .destructive) {
                        Task { await model.humanStop() }
                    } label: {
                        Label("PARADA", systemImage: "stop.fill")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityHint("Detiene el estabilizador sin esperar una conexión nueva")
                }

                Section("Zonas") {
                    ForEach(model.zones, id: \.name) { zone in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(zone.name)
                                if zone.forbidden { Text("Prohibida").font(.caption).foregroundStyle(.red) }
                            }
                            Spacer()
                            if !zone.forbidden {
                                Button("Mirar") { Task { await model.look(zone: zone.name) } }
                                    .disabled(!model.status.connected)
                            }
                        }
                    }
                    TextField("Nombre de zona", text: $zoneName)
                    Toggle("Zona prohibida", isOn: $forbidden)
                    Button("Guardar zona aquí") {
                        Task {
                            zoneConfirmationDraft = await model.prepareZone(name: zoneName, forbidden: forbidden)
                            showZoneConfirmation = zoneConfirmationDraft != nil
                        }
                    }
                    .disabled(!model.status.connected || model.status.pose == nil ||
                              zoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !model.status.referenceReady && !model.zones.isEmpty {
                    Section("Referencia") {
                        Text("Comprueba físicamente la referencia y todas las zonas antes de confirmarla.")
                        Button("Confirmar referencia") {
                            Task {
                                await model.prepareReference()
                                showReferenceConfirmation = model.referenceDraft != nil
                            }
                        }
                        .disabled(!model.status.connected || model.status.pose == nil)
                    }
                }

                if let error = model.errorMessage {
                    Section("Aviso") { Text(error).foregroundStyle(.red) }
                }

                Section("Registro") {
                    ForEach(Array(model.audit.suffix(20).enumerated()), id: \.offset) { item in
                        let entry = item.element
                        Text("\(entry.date.formatted()) · \(entry.event)")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("GimbalKit")
            .alert("Guardar zona aquí", isPresented: $showZoneConfirmation) {
                Button("Guardar") {
                    guard let draft = zoneConfirmationDraft else { return }
                    Task {
                        await model.confirmZone(draft)
                        zoneConfirmationDraft = nil
                        zoneName = ""
                    }
                }
                Button("Cancelar", role: .cancel) {
                    model.cancelZone(zoneConfirmationDraft)
                    zoneConfirmationDraft = nil
                }
            } message: {
                if let draft = zoneConfirmationDraft {
                    Text("Crear \(draft.zone.name) alrededor de yaw \(draft.pose.yaw.formatted(.number.precision(.fractionLength(1))))° y pitch \(draft.pose.pitch.formatted(.number.precision(.fractionLength(1))))°.")
                }
            }
            .alert("Confirmar referencia", isPresented: $showReferenceConfirmation) {
                Button("He comprobado las zonas") { Task { await model.confirmReference() } }
                Button("Cancelar", role: .cancel) { model.cancelReference() }
            } message: {
                Text("Confirma solo después de comprobar físicamente la orientación inicial y las zonas guardadas.")
            }
        }
    }
}
~~~

La alerta confirma el ZoneDraft devuelto por prepareZone, incluidas su sesión y pose; el botón Guardar pasa ese mismo valor a confirmZone. Cancelar limpia solo el borrador coincidente. Una sesión o pose fuera de la tolerancia vigente hace que HostRuntime aborte antes de persistir. La vista nunca usa driver, controlador o socket directamente.

- [ ] **Step 3: Crear el puente iPhone WatchConnectivity**

Apps/GimbalPhone/PhoneWatchBridge.swift:

~~~swift
import Foundation
@preconcurrency import WatchConnectivity
import GimbalHostSupport
import GimbalKit
import GimbalWatchKit

@MainActor
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    private let session = WCSession.default
    private let service: PhoneWatchService
    private var activated = false
    private var outputTask: Task<Void, Never>?

    init(service: PhoneWatchService) {
        self.service = service
        super.init()
    }

    func activate() {
        guard !activated, WCSession.isSupported() else { return }
        activated = true
        session.delegate = self
        session.activate()
        outputTask = Task { [weak self, service] in
            for await output in service.outputs {
                guard let self else { return }
                await self.publish(output)
            }
        }
        Task { await service.setReachable(session.isReachable) }
    }

    private func publish(_ output: PhoneWatchOutput) async {
        switch output {
        case let .event(envelope):
            let decision = PhoneWatchEventPublication.decision(
                for: envelope,
                currentStopCounter: service.stopCounter.read()
            )
            switch decision {
            case let .send(current):
                sendEvent(current)
            case .discard:
                break
            case let .correctStaleArrival(stopped):
                await service.replaceLatestTerminalEvent(stopped)
                sendEvent(stopped)
            }
            await service.refreshStatus()
        case let .status(status):
            try? session.updateApplicationContext(WatchMessageCodec.encodeStatus(status))
        }
    }

    private func sendEvent(_ envelope: WatchEventEnvelope) {
        guard session.isReachable else { return }
        session.sendMessage(WatchMessageCodec.encodeEvent(envelope), replyHandler: nil, errorHandler: nil)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let request = try? WatchMessageCodec.decodeRequest(message)
        let sessionID = (message["session"] as? String).flatMap(UUID.init(uuidString:))
        let operationID = (message["operationID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let request {
                await service.receive(request)
            } else {
                await service.rejectMalformed(session: sessionID, operationID: operationID)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            await self?.service.setReachable(reachable)
        }
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            await service.setReachable(reachable)
            await service.refreshStatus()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {}
}
~~~

El callback convierte el diccionario a DTO Sendable en su propia cola; solo UUID, Bool o DTO cruzan a MainActor. No captura el diccionario, WCSession ni reply handler. Justo antes de sendMessage compara el stopCounter con el token del evento; elimina resultados de generación antigua. Si la llegada está obsoleta, publica `stopped` para esa operationID y sustituye el terminal guardado antes de refrescar application context. Un `stopped` obsoleto no se envía como evento inmediato; el terminal del contexto recupera el resultado. Cada evento usa sendMessage si hay alcance y el estado final, incluido el terminal, se conserva con updateApplicationContext. No usar transferUserInfo.

- [ ] **Step 4: Crear el cliente, la app y la vista Watch completas**

Apps/GimbalWatch/WatchConnectivityClient.swift:

~~~swift
import Foundation
import Observation
@preconcurrency import WatchConnectivity
import GimbalWatchKit

@MainActor
@Observable
final class WatchConnectivityClient: NSObject, WCSessionDelegate {
    private let session = WCSession.default
    private var activated = false
    private var sessionID = UUID()
    private var sequence: UInt64 = 0
    private var operationState = WatchOperationState()

    private(set) var reachable = false
    private(set) var status: WatchStatus?
    private(set) var lastEvent: WatchEvent?
    private(set) var connectionError: String?

    var currentOperationID: UUID? { operationState.currentOperationID }

    func activate() {
        guard !activated, WCSession.isSupported() else { return }
        activated = true
        sessionID = UUID()
        session.delegate = self
        session.activate()
        reachable = session.isReachable
        requestStatus()
    }

    func requestStatus() {
        send(WatchRequest(session: sessionID, seq: nextSequence(), operationID: nil,
                          stopToken: nil, command: .status))
    }

    func stop() {
        let id = UUID()
        operationState.begin(id)
        send(WatchRequest(session: sessionID, seq: nextSequence(), operationID: id,
                          stopToken: nil, command: .stop))
    }

    func look(zone: String) {
        guard let token = status?.stopToken else {
            requestStatus()
            return
        }
        let id = UUID()
        operationState.begin(id)
        send(WatchRequest(session: sessionID, seq: nextSequence(), operationID: id,
                          stopToken: token, command: .look(zone: zone)))
    }

    private func nextSequence() -> UInt64 {
        precondition(sequence < UInt64.max, "Secuencia Watch agotada; reinicia la sesión")
        sequence += 1
        return sequence
    }

    private func send(_ request: WatchRequest) {
        guard session.isReachable else {
            reachable = false
            connectionError = "iPhone fuera de alcance"
            return
        }
        connectionError = nil
        session.sendMessage(WatchMessageCodec.encodeRequest(request),
                            replyHandler: nil, errorHandler: nil)
    }

    private func receive(_ envelope: WatchEventEnvelope) {
        guard envelope.session == nil || envelope.session == sessionID,
              let event = operationState.apply(envelope.event) else { return }
        lastEvent = event
    }

    private func receive(_ status: WatchStatus) {
        self.status = status
        if let terminalEvent = status.terminalEvent { receive(terminalEvent) }
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reachable = reachable
            if reachable { self.requestStatus() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reachable = reachable
            if reachable { self.requestStatus() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let status = try? WatchMessageCodec.decodeStatus(applicationContext)
        Task { @MainActor [weak self] in
            if let status { self?.receive(status) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let envelope = try? WatchMessageCodec.decodeEvent(message)
        Task { @MainActor [weak self] in
            if let envelope { self?.receive(envelope) }
        }
    }
}
~~~

Apps/GimbalWatch/GimbalWatchApp.swift:

~~~swift
import SwiftUI

@main
@MainActor
struct GimbalWatchApp: App {
    @State private var client = WatchConnectivityClient()

    var body: some Scene {
        WindowGroup {
            WatchHomeView(client: client)
                .task { client.activate() }
        }
    }
}
~~~

Apps/GimbalWatch/WatchHomeView.swift:

~~~swift
import Observation
import GimbalWatchKit
import SwiftUI
import WatchKit

@MainActor
struct WatchHomeView: View {
    @Bindable var client: WatchConnectivityClient

    var body: some View {
        VStack(spacing: 8) {
            Button(action: client.stop) {
                Label("PARAR", systemImage: "stop.fill")
                    .font(.headline.bold())
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)

            Text(client.reachable ? "iPhone conectado" : "iPhone no alcanzable")
                .font(.caption)
            if let error = client.connectionError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            if let status = client.status {
                Text(status.connected ? "Osmo conectada" : "Osmo desconectada")
                    .font(.caption)
                if let battery = status.batteryPercent { Text("Batería: \(battery)%").font(.caption) }
                if let pose = status.pose {
                    Text("Yaw \(pose.yaw.formatted(.number.precision(.fractionLength(0))))° · Pitch \(pose.pitch.formatted(.number.precision(.fractionLength(0))))°")
                        .font(.caption2)
                }
            }
            if case let .rejected(_, reason)? = client.lastEvent {
                Text("Rechazado: \(reason.rawValue)").font(.caption2).foregroundStyle(.red)
            }

            List(client.status?.zoneNames ?? [], id: \.self) { zone in
                Button {
                    client.look(zone: zone)
                } label: {
                    Label(zone, systemImage: "viewfinder")
                }
                .disabled(!client.reachable || client.status?.stopToken == nil)
            }
        }
        .onChange(of: client.lastEvent) { _, event in
            guard let event else { return }
            switch event {
            case .arrived(_, _):
                WKInterfaceDevice.current().play(.success)
            case .stopped(_, _):
                WKInterfaceDevice.current().play(.stop)
            case .rejected:
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }
}
~~~

El reloj asigna session UUID al activar, aumenta seq en cada mensaje, guarda operationID antes de enviar look y STOP, y adjunta el último stopToken publicado por el iPhone en cada look. Sin token recibido, solicita estado y no envía look. La corona desplaza List de forma nativa. El Watch no contiene BLE, velocidades ni lógica de autorización.

- [ ] **Step 5: Generar Xcode y compilar ambos destinos**

~~~sh
cd Apps
/opt/homebrew/bin/xcodegen generate --spec project.yml
cd ..
xcodebuild -project Apps/GimbalKitApps.xcodeproj -scheme GimbalPhone \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Apps/GimbalKitApps.xcodeproj -scheme GimbalWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
~~~

Expected: XcodeGen acepta ambos info.path, agrega GimbalWatch en la fase de contenido Watch del iPhone, muestra ambos schemes, registra GimbalKitIntentsPackage.self y ambos builds acaban sin firma. No arrancar simuladores. Si el sandbox bloquea SDK/build, conservar el error completo para que Jesús pueda repetirlo fuera del sandbox.

Antes de compilar, comprobar los dos plist que generó XcodeGen:

~~~sh
plutil -lint Apps/GimbalPhone/Info.plist Apps/GimbalWatch/Info.plist
/usr/libexec/PlistBuddy -c 'Print :NSBluetoothAlwaysUsageDescription' Apps/GimbalPhone/Info.plist
/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' Apps/GimbalPhone/Info.plist
/usr/libexec/PlistBuddy -c 'Print :WKApplication' Apps/GimbalWatch/Info.plist
/usr/libexec/PlistBuddy -c 'Print :WKCompanionAppBundleIdentifier' Apps/GimbalWatch/Info.plist
~~~

Expected: los plist generados contienen permiso Bluetooth, `bluetooth-central`, `WKApplication = true` y el companion `dev.gimbalkit.phone`; ningún valor depende de un plist preexistente como plantilla.

- [ ] **Step 6: Ejecutar tests y build portable sin los cuatro sockets**

~~~sh
CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build \
  --skip httpLoopbackUsesEphemeralPortAndChecksCredentialsAndOrigin \
  --skip incompleteHTTPRequestTimesOutWithoutRealSleep \
  --skip seventeenthRealLoopbackPeerIsClosedWhileSixteenRemainUsable \
  --skip cliCommandsUseMCPAndBadCredentialsFail
~~~

Expected: 121 pruebas preexistentes intactas y todas las pruebas nuevas de counter, intents, codec, host iPhone y PhoneWatchService pasan. Las cuatro pruebas loopback permanecen en sus targets y se ejecutan aparte fuera del sandbox. No se arrancan simuladores en ninguna tarea.


### Task 7 — MANUAL: instalación y validación con iPhone, Watch y Osmo

**Files:**
- No requiere cambios adicionales. Evidencias solo si Jesús decide documentarlas después.

- [ ] Firmar e instalar GimbalPhone en el iPhone con la cuenta y equipo de Jesús; aceptar permiso Bluetooth. Ver conexión, reconexión, batería, pose, zonas, referencia, registro y PARADA. Confirmar en el dispositivo que no se inicia listener MCP.
- [ ] Guardar una zona, cancelar el diálogo y verificar que no se persiste; guardar otra y confirmar. Reconectar y verificar que la referencia vuelve a requerir confirmación.
- [ ] Probar “Mirar a zona”, “Parar”, “Estado” y “Guardar zona aquí” desde Atajos/Siri en español, con app en foreground y background. Repetir con Osmo apagada; medir que mirar aborta/cancela antes de 10 s y que no envía movimiento.
- [ ] Con GimbalPhone cerrado o sin ventana visible, provocar un mensaje del Watch que despierte el iPhone; comprobar que el bootstrap de App.init activa WCSession/runtime, responde status y procesa STOP sin presentar PhoneHomeView.
- [ ] Instalar y emparejar GimbalWatch. Ver estado, batería, pose y zonas; verificar que Watch no pide permiso Bluetooth. Mirar una zona y verificar háptica de llegada.
- [ ] Durante preparación y durante mirada, pulsar STOP del iPhone, Atajos y Watch en pruebas separadas; comprobar STOP inmediato, silencio Watch de 2 s, rechazo de órdenes previas y ausencia de llegada tardía. Comprobar que un resultado terminal llega también por application context si se pierde el evento sendMessage. Repetir perdiendo alcance del Watch antes de que termine la preparación.
- [ ] Confirmar que la corona solo desplaza la lista. Medir la respuesta de STOP con Watch sin alcance y al recuperarlo. No añadir acciones que muevan por corona.
- [ ] Jesús realiza firma e instalación en dispositivos reales. No ajustar límites, zonas ni referencias para obtener un PASS; documentar valores observados.

## Autorrevisión

- **Alcance:** seis tareas automáticas ordenadas sin dependencia futura; la séptima es manual. Solo este plan y la tabla de trampas son artefactos de esta redacción.
- **HostRuntime:** conserva el protocolo MCP y el camino original de look; el overload antiguo mantiene llamadas existentes. El token se chequea al entrar y tras cada suspensión previa al navegador; después de requestLease una discrepancia libera el lease. Un STOP posterior a ese guard usa la revocación existente. Los dos STOP incrementan primero incluso offline.
- **Camino de seguridad:** no se reemplazan navegador, controlador, política, leases, épocas ni driver. Watch no manda velocidad, no hay intent relativo y no se cambia cadencia.
- **Concurrencia Watch:** STOP se despacha aun con seq repetido o anterior; máximos/barrera solo avanzan. token, operationID y bandera activa se fijan antes del primer await; reachability fija quietUntil y corta preparación antes de suspender; cleanup y publicaciones verifican identidad/counter.
- **Mensajes:** DTO Sendable, codec de diccionarios-objeto, stopCounter en llegada/parada, motivo real, terminal recuperable en application context, deduplicación por el mismo reducer, sin transferUserInfo.
- **App Intents:** confirmación iOS 17 exacta después de preparar el mismo ZoneDraft que se persiste; cancelar no escribe y sesión/pose cambiadas abortan. ProvidesDialog; includedPackages no aislado y con metatipos; cuatro intents sin movimiento relativo.
- **App iPhone:** bootstrap de bridge/runtime en GimbalPhoneApp.init, sin dependencia de `.task` en PhoneHomeView; la prueba de entorno no crea una vista y la tarea manual cubre despertar desde Watch en background.
- **Portabilidad:** defaultURL con Application Support; HostModel, HostInstanceLock y LocalFiles macOS-only; GimbalService permanece disponible; `info.properties` declara permisos/background/companion. swift build macOS y builds Xcode iOS/watchOS aparecen en las tareas correspondientes.
- **Regresión:** 121 pruebas preexistentes permanecen sin editar y se ejecutan; cuatro pruebas loopback se conservan y se ejecutan aparte fuera del sandbox. No se copian fixtures ni se cambia la distribución de targets.
- **Límites:** el build de simulador no verifica permisos del sistema, background real, emparejamiento, alcance, Siri ni telemetría física; todo eso está en Task 7 manual.
