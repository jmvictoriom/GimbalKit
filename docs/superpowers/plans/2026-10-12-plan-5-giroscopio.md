# GimbalKit — Plan 5: pose de alta frecuencia con el giroscopio del iPhone

> Plan de implementación futuro. Este encargo solo redacta el plan y la tabla de trampas: no implementar código, ejecutar pruebas o builds, usar red/Bluetooth, conectar hardware, lanzar simuladores ni hacer commits.

**Goal:** Sustituir la pose retardada de ~1 Hz por una estimación relativa del giroscopio del iPhone, anclada periódicamente a la orientación absoluta de la Osmo, y ofrecer navegación rápida solo con calibración y pose fiables. Sin calibración o ante cualquier fallo, conservar el navegador lento actual.

**Architecture:** Un módulo Swift puro GimbalMotionKit contiene cuaterniones, muestras monotónicas, calibración de ejes, estimador, métricas de fiabilidad y un FusedPoseDevice que envuelve el OMDevice. El estimador nunca inventa el cero: solo calcula el offset con la Osmo quieta y asentada, usa giros relativos del iPhone durante el movimiento y vuelve a anclar en reposo. La app iOS inyecta CoreMotion, guarda la calibración y elige el perfil; HostRuntime verifica la fiabilidad y, si se degrada durante una mirada rápida, deja terminar y parar la navegación rápida antes de reanudar la misma zona con el perfil lento. Los caminos MCP y Watch siguen usando el perfil actual.

**Tech Stack:** Swift 6 estricto, SwiftPM, Swift Testing, Foundation, CoreMotion, SwiftUI y XcodeGen. Sin dependencias externas. El módulo de fusión compila y se prueba en macOS; el adaptador real y sus vistas compilan para iOS 17.

**Spec:** docs/superpowers/specs/2026-10-11-gimbalkit-v1-design.md (§2, §3, §4 y §8), docs/superpowers/plans/ESTADO.md, docs/research/telemetria-om-se.md, Sources/GimbalKit (en especial GotoNavigator.swift, NavigationSafety.swift, PoseFeedback.swift y GimbalController.swift), Sources/GimbalHostSupport, Sources/GimbalKitSim y las cinco auditorías auditoria-plan-4-informe{,2,3,4,5}.md.

## Global Constraints

- La tarea de hoy modifica únicamente este plan y plan-5-trampas.md. No editar código, pruebas existentes ni configuración; no correr tests/builds, abrir simuladores, iniciar Bluetooth, contactar hardware, usar red o hacer commits.
- La implementación futura es aditiva. En GimbalKit, los únicos cambios funcionales permitidos son inyectar NavigationLimits en el init de GotoNavigator con valor por defecto NavigationLimits(), idéntico al actual, y añadir NavigationLimits.fast en NavigationSafety.swift. No modificar GimbalController.swift, OMDevice.swift, ningún archivo de GimbalKitDJI, PhoneWatchService.swift, GimbalKitMCP ni los 193 tests actuales. Los 193 tests se conservan byte por byte; los nuevos casos van en ficheros de test nuevos.
- GimbalMotionKit no importa CoreMotion, UIKit, GimbalKitDJI ni Bluetooth. Depende solo de Foundation y GimbalKit. El adaptador CoreMotion vive en Apps/GimbalPhone y entrega cuaterniones normalizados con CMDeviceMotion.timestamp monotónico.
- PhoneHostEnvironment.shared sigue siendo la única instancia que usan GimbalPhone y App Intents. Recibe un GyroSourceSlot estable; GimbalPhone instala CoreMotionGyroSource en ese slot antes de arrancar el modelo y carga la calibración guardada antes de iniciar la conexión. Si el slot está vacío en un arranque en background, mantiene el stream abierto sin muestras: HostRuntime usa Osmo y perfil lento, no crea otro HostRuntime ni falla la conexión. Una instalación posterior empieza a reenviar gyro al mismo stream.
- La Osmo es la referencia absoluta. Un ancla requiere calibración vigente, dos muestras Osmo nuevas y quietas, ≥2 s desde el último STOP/pulso y giroscopio quieto. El ancla guarda poseOsmo − poseGiro. Durante el movimiento se suma el giro relativo transformado a los ejes del gimbal. Nunca se reancla durante movimiento.
- El error de reanclaje se mide en yaw/pitch con diferencia circular para yaw. Un error >3° invalida la fiabilidad y la calibración periódica; no se corrige ocultando el error con un offset nuevo. Si el ancla tiene >20 s durante movimiento, el sensor tiene ≥0,2 s de edad, falta calibración, cambió la orientación de pantalla o hay una muestra no válida, se usa el perfil lento.
- La calibración guiada toma muestras alrededor de dos microgiros de yaw y pitch (~3°, nunca >6°/s) usando GotoNavigator, una zona temporal no persistida dentro de la zona permitida actual, el lease existente y NavigationSafety.check. Si no hay margen seguro suficiente o una zona prohibida invade el recorrido, se aborta sin ordenar movimiento. La vista exige trípode/base estable, espacio despejado y referencia confirmada.
- El perfil lento conserva exactamente los valores actuales: 6°/s, deadband 2°, pulso 0,30 s, asentamiento 0,90 s, frescura 1,5 s y plazo 25 s. NavigationLimits.fast usa como máximo 6°/s en este plan, deadband 1,5°, pulso 0,20 s, asentamiento 0,25 s y frescura 0,20 s. Su horizonte de seguridad incluye hasta 0,10 s de edad real del gyro y 0,25 s de frenado conservador, y se verifica con NavigationSafety.check. Si la medida física de frenado supera 0,25 s, no habilitar el perfil rápido hasta recalcular y auditar la envolvente.
- La SafetyPolicy del runtime continúa en 6°/s. fastNavigationEnabled es una preferencia independiente, apagada por defecto y deshabilitada hasta guardar una calibración válida. Este plan no eleva el límite a 12°/s: el GimbalController real también conserva NavigationLimits() con máximo 6°, así que cambiar solo SafetyPolicy no permitiría 12°/s. Cualquier subida requiere otro cambio aprobado que cubra ambos guardias y una medición manual previa.
- HostRuntime conserva las firmas MCP actuales y el overload look(zone:leaseSeconds:stopToken:) existente. El overload que recibe el perfil es solo una elección de perfil. MCP y PhoneWatchService llaman las firmas existentes y siguen en lento. No se añaden órdenes, secuencias, leases ni epochs. Toda ruta nueva vuelve a comprobar token de STOP e identidad de rig después de cada await que pueda preceder a movimiento o a publicar llegada.
- FusedPoseDevice reenvía sin cambios capabilities, comandos y STOP al OMDevice. Con pose fiable publica una PoseSample nueva por muestra gyro válida, sequence estrictamente creciente y receivedAt renovado. Cuando no se exige gyro fiable devuelve la muestra Osmo original para que el navegador lento conserve la frescura de 1,5 s. El modo rápido devuelve nil si deja de cumplir su puerta de fiabilidad.
- La vista expone calibración, error medio/máximo, edad del ancla, edad del gyro y razón de fallback. GimbalMotionKit ofrece un DTO/log JSONL importable en GimbalLab; el Mac no comparte en vivo el sensor físico del iPhone, por lo que la revisión de una sesión real se hace exportando el log del teléfono e importándolo en GimbalLab.
- Pruebas deterministas: GyroSource simulado, relojes monotónicos manuales, poses Osmo sintéticas y el LaggedPoseDevice existente. Ninguna prueba abre BLE, sockets, duerme tiempo real o arranca simuladores. La ejecución completa futura omite únicamente las cuatro pruebas loopback existentes durante el sandbox, sin moverlas ni editarlas.

## Review Focus

- Calibración sintética de montajes vertical, horizontal e invertido; signos yaw/pitch; roll como producto vectorial; rechazo si el giro medido <1,5° o el ángulo entre ejes no está entre 80° y 100°.
- Cuaterniones no finitos, norma fuera de 0,9...1,1, timestamp negativo/no finito, timestamp repetido/regresivo y salto >0,20 s: no generan PoseSample fusionada ni movimiento rápido.
- El ancla inicial y cada reanclaje exigen dos secuencias Osmo nuevas, quietud Osmo y gyro, y 2 s sin STOP/pulso. Una muestra durante movimiento nunca cambia el offset.
- Discrepancia al reanclar >3° invalida la fuente; edad de ancla >20 s durante movimiento, gyro mudo ≥0,2 s, rotación física manual del teléfono y cambio de orientación desactivan rápido y muestran el motivo.
- Un gyro válido renueva secuencia y receivedAt en cada muestra. Sin fiabilidad, el adaptador lento entrega telemetría Osmo sin refrescar falsamente su timestamp.
- NavigationLimits() y GotoNavigator(controller:clock:) mantienen exactamente su resultado actual y compilan consumidores existentes de GimbalLab. NavigationLimits.fast rechaza muestras mayores de 0,20 s y su Safety.check contempla el peor retraso y frenado declarados.
- Solo la app con fastNavigationEnabled y fiabilidad actual solicita el perfil rápido; HostRuntime vuelve a comprobar. Una pérdida de fiabilidad detiene y libera la mirada rápida, valida el mismo token/rig y solo entonces adquiere un lease nuevo para continuar en lento. STOP durante degradación nunca da paso a un SPEED ni a una llegada antigua.
- Calibración y fallback no crean productores de velocidad en paralelo; STOP, leases y serialización del controlador actual siguen siendo dueños de cada escritura. El calibrador restaura zonas temporales en éxito, error, cancelación y STOP.
- El export/import JSONL preserva timestamp, calibración, ancla, errores, edad del gyro y motivo; JSON inválido, NaN/Inf y versión desconocida fallan con error tipado.
- Builds de paquete para macOS e iOS verifican Swift 6 y CoreMotion sin abrir simuladores. El test de STOP rápido usa el fake de link actual y comprueba la lista de escrituras después de completar STOP.
- La validación manual compara ambos sensores en ±20°, mide parada y cadencia real, hace un giro manual del teléfono, desconecta el gyro y cambia orientación. No se propone 12°/s hasta tener un margen de seguridad medido.

## File Structure

~~~text
Package.swift                                         # producto/target MotionKit; deps directas Sim, HostSupport, LabSupport y test targets
Sources/GimbalKit/NavigationSafety.swift             # NavigationLimits.fast; default y NavigationSafety.check permanecen
Sources/GimbalKit/GotoNavigator.swift                # parámetro limits con default actual y guardia stale por perfil
Sources/GimbalMotionKit/
  MotionGeometry.swift                               # MotionVector3 y MotionQuaternion
  GyroSource.swift                                   # GyroSample, GyroSource, DisplayOrientation
  GyroSourceSlot.swift                               # fuente delegada estable para la instancia shared del host
  AxisCalibration.swift                              # trials y transformación fija teléfono→gimbal
  PoseReliability.swift                              # métricas, umbrales y causas
  FusedPoseEstimator.swift                           # offset absoluto, validación y reanclaje
  FusedPoseDevice.swift                              # adaptador PoseFeedbackDevice/GimbalDevice
  GyroDiagnosticsLog.swift                           # snapshots Codable y JSONL
Sources/GimbalHostSupport/
  HostRuntime.swift                                  # wiring del adaptador, calibración y perfil/fallback
  PhoneHostEnvironment.swift                         # inyección opcional GyroSource sin cambiar el default
  PhoneHostModel.swift                               # selección perfil, ajustes y métricas
  GyroCalibrationRunner.swift                        # dos microgiros con zonas temporales y token STOP
Sources/GimbalKitSim/
  SimulatedGyroSource.swift                          # fuente de muestras controlable por pruebas
Tests/GimbalMotionKitTests/
  GyroTestFixtures.swift
  AxisCalibrationTests.swift
  FusedPoseEstimatorTests.swift
  FusedPoseDeviceTests.swift
Tests/GimbalKitTests/
  NavigationProfileTests.swift                      # fichero nuevo; no editar los 193 casos actuales
Tests/GimbalHostSupportTests/
  GyroFastNavigationTests.swift                     # fichero nuevo; STOP, lease y degradación
Apps/project.yml                                     # añadir productos y NSMotionUsageDescription en info.properties
Apps/GimbalPhone/
  GimbalPhoneApp.swift                               # environment iOS con CoreMotionGyroSource
  PhoneHomeView.swift                                # entrada de ajustes/calibración
  CoreMotionGyroSource.swift                         # CMMotionManager a ~100 Hz, solo iOS
  GyroSettingsView.swift                             # calibración, perfil y métricas
Apps/Tests/
  GyroSettingsTests.swift                            # decisiones de perfil con dependencias falsas
Sources/GimbalLabSupport/
  LabModel.swift                                     # cargar snapshots diagnósticos exportados
Sources/GimbalLabMac/GimbalLabApp.swift              # importar JSONL y mostrar errores/edad
Tests/GimbalKitDJITests/
  GyroDiagnosticsLabTests.swift                     # fichero nuevo; lectura de log compartido
~~~

---

### Task 1 — Geometría de giros y calibración de ejes

**Files:**
- Create: Sources/GimbalMotionKit/MotionGeometry.swift, GyroSource.swift, AxisCalibration.swift
- Modify: Package.swift (producto y target puro GimbalMotionKit)
- Create: Tests/GimbalMotionKitTests/GyroTestFixtures.swift, AxisCalibrationTests.swift

**Interfaces:**
- Consumes: GimbalKit.PoseSample(pose:receivedAt:sequence:); la telemetría absoluta existente de OMDevice; dos GyroSample de inicio/fin por microgiro.
- Produces: public struct MotionVector3: Sendable, Equatable, Codable { public let x: Double; public let y: Double; public let z: Double; public init(x: Double, y: Double, z: Double); public var length: Double; public var normalized: MotionVector3?; public func dot(_ other: MotionVector3) -> Double; public func cross(_ other: MotionVector3) -> MotionVector3 }.
- Produces: public struct MotionQuaternion: Sendable, Equatable, Codable { public let x: Double; public let y: Double; public let z: Double; public let w: Double; public init(x: Double, y: Double, z: Double, w: Double); public init(axis: MotionVector3, angleRadians: Double); public var normalized: MotionQuaternion?; public var conjugate: MotionQuaternion; public func rotationVector() -> MotionVector3?; public static func * (lhs: MotionQuaternion, rhs: MotionQuaternion) -> MotionQuaternion }.
- Produces: public enum DisplayOrientation: String, Sendable, Codable, Equatable { case unknown, portrait, portraitUpsideDown, landscapeLeft, landscapeRight }.
- Produces: public struct GyroSample: Sendable, Equatable { public let attitude: MotionQuaternion; public let timestamp: TimeInterval; public let displayOrientation: DisplayOrientation; public init(attitude: MotionQuaternion, timestamp: TimeInterval, displayOrientation: DisplayOrientation = .portrait) } y public protocol GyroSource: Sendable { func start() async throws -> AsyncStream<GyroSample>; func stop() async; func updateDisplayOrientation(_ orientation: DisplayOrientation) async }.
- Produces: public actor GyroSourceSlot: GyroSource { public init(); public func install(_ source: any GyroSource) async; public func start() async throws -> AsyncStream<GyroSample>; public func stop() async; public func updateDisplayOrientation(_ orientation: DisplayOrientation) async }.
- Produces: public enum GimbalMotionAxis: Sendable, Equatable { case yaw, pitch }; public struct GyroCalibrationTrial: Sendable { public let axis: GimbalMotionAxis; public let gyroStart: GyroSample; public let gyroEnd: GyroSample; public let osmoStart: PoseSample; public let osmoEnd: PoseSample; public init(axis: GimbalMotionAxis, gyroStart: GyroSample, gyroEnd: GyroSample, osmoStart: PoseSample, osmoEnd: PoseSample) }.
- Produces: public struct AxisCalibration: Sendable, Equatable, Codable { public let yawAxisInPhone: MotionVector3; public let pitchAxisInPhone: MotionVector3; public let rollAxisInPhone: MotionVector3; public let displayOrientation: DisplayOrientation; public let version: Int; public init(yawAxisInPhone: MotionVector3, pitchAxisInPhone: MotionVector3, displayOrientation: DisplayOrientation) throws; public static func derive(yaw: GyroCalibrationTrial, pitch: GyroCalibrationTrial, displayOrientation: DisplayOrientation) throws -> AxisCalibration }.
- Produces: public enum GyroCalibrationError: Error, Sendable, Equatable { case invalidSample, insufficientRotation, axesNotOrthogonal, wrongTrialAxis, invalidOrientation }.
- Produces: public enum GyroSourceError: Error, Sendable, Equatable { case unavailable, alreadyRunning, invalidSample }.
- El GyroSourceSlot conserva un stream único por ejecución, puede estar vacío al inicio y reenvía el stream de la fuente instalada; install inicia forwarding si el stream ya está abierto. updateDisplayOrientation se aplica a la fuente y a cada GyroSample emitida; stop cancela forwarding, termina ese stream y detiene la fuente. Cada start posterior crea otra ejecución para cubrir reconexiones.

- [ ] **Step 1: Escribir la prueba roja**

Añadir en GyroTestFixtures.swift los fixtures sintéticos completos y en AxisCalibrationTests.swift estas pruebas. Los cuaterniones se crean desde ejes arbitrarios; los valores de Osmo se usan solo para fijar el signo positivo de cada eje.

~~~swift
import Foundation
import GimbalKit
import GimbalMotionKit

enum GyroTestFixtures {
    static func q(_ axis: MotionVector3, _ degrees: Double) -> MotionQuaternion {
        MotionQuaternion(axis: axis, angleRadians: degrees * .pi / 180)
    }

    static func sample(_ axis: MotionVector3 = MotionVector3(x: 0, y: 1, z: 0),
                       _ degrees: Double = 0, _ time: Double) -> GyroSample {
        GyroSample(attitude: q(axis, degrees), timestamp: time)
    }

    static func pose(_ yaw: Double, _ pitch: Double, _ sequence: UInt64) -> PoseSample {
        PoseSample(pose: Pose(yaw: yaw, pitch: pitch),
                   receivedAt: Date(timeIntervalSince1970: Double(sequence)),
                   sequence: sequence)
    }

    static func trial(_ axis: GimbalMotionAxis, phoneAxis: MotionVector3,
                      yaw: Double, pitch: Double, amount: Double = 3) -> GyroCalibrationTrial {
        GyroCalibrationTrial(
            axis: axis,
            gyroStart: sample(phoneAxis, 0, 1),
            gyroEnd: sample(phoneAxis, amount, 2),
            osmoStart: pose(0, 0, 1),
            osmoEnd: pose(yaw, pitch, 2)
        )
    }
}
~~~

~~~swift
import Testing
import GimbalMotionKit

@Test func calibrationRecoversAxesForPortraitLandscapeAndInvertedMounts() throws {
    let mounts: [(DisplayOrientation, MotionVector3, MotionVector3)] = [
        (.portrait, MotionVector3(x: 0, y: 1, z: 0), MotionVector3(x: 1, y: 0, z: 0)),
        (.landscapeLeft, MotionVector3(x: 1, y: 0, z: 0), MotionVector3(x: 0, y: 0, z: 1)),
        (.portraitUpsideDown, MotionVector3(x: 0, y: -1, z: 0), MotionVector3(x: -1, y: 0, z: 0))
    ]
    for (orientation, yawAxis, pitchAxis) in mounts {
        let yaw = GyroTestFixtures.trial(.yaw, phoneAxis: yawAxis, yaw: 3, pitch: 0)
        let pitch = GyroTestFixtures.trial(.pitch, phoneAxis: pitchAxis, yaw: 0, pitch: 3)
        let calibration = try AxisCalibration.derive(yaw: yaw, pitch: pitch,
                                                     displayOrientation: orientation)
        #expect(calibration.yawAxisInPhone == yawAxis)
        #expect(calibration.pitchAxisInPhone == pitchAxis)
        #expect(abs(calibration.yawAxisInPhone.dot(calibration.pitchAxisInPhone)) < 0.001)
        #expect(abs(calibration.rollAxisInPhone.length - 1) < 0.001)
        #expect(calibration.displayOrientation == orientation)
    }
}

@Test func calibrationRejectsSmallNonOrthogonalAndNonFiniteTrials() {
    let yawAxis = MotionVector3(x: 0, y: 1, z: 0)
    let pitchAxis = MotionVector3(x: 1, y: 0, z: 0)
    let tooSmallYaw = GyroTestFixtures.trial(.yaw, phoneAxis: yawAxis, yaw: 1, pitch: 0, amount: 1)
    let pitch = GyroTestFixtures.trial(.pitch, phoneAxis: pitchAxis, yaw: 0, pitch: 3)
    #expect(throws: GyroCalibrationError.insufficientRotation) {
        try AxisCalibration.derive(yaw: tooSmallYaw, pitch: pitch, displayOrientation: .portrait)
    }

    let nonOrthogonal = GyroTestFixtures.trial(.pitch,
        phoneAxis: MotionVector3(x: 0.5, y: 0.8660254, z: 0), yaw: 0, pitch: 3)
    #expect(throws: GyroCalibrationError.axesNotOrthogonal) {
        try AxisCalibration.derive(
            yaw: GyroTestFixtures.trial(.yaw, phoneAxis: yawAxis, yaw: 3, pitch: 0),
            pitch: nonOrthogonal, displayOrientation: .portrait
        )
    }

    let bad = GyroSample(attitude: MotionQuaternion(x: .infinity, y: 0, z: 0, w: 1), timestamp: 2)
    let invalid = GyroCalibrationTrial(axis: .yaw, gyroStart: GyroTestFixtures.sample(yawAxis, 0, 1),
        gyroEnd: bad, osmoStart: GyroTestFixtures.pose(0, 0, 1), osmoEnd: GyroTestFixtures.pose(3, 0, 2))
    #expect(throws: GyroCalibrationError.invalidSample) {
        try AxisCalibration.derive(yaw: invalid, pitch: pitch, displayOrientation: .portrait)
    }

    let validYaw = GyroTestFixtures.trial(.yaw, phoneAxis: yawAxis, yaw: 3, pitch: 0)
    #expect(throws: GyroCalibrationError.wrongTrialAxis) {
        try AxisCalibration.derive(yaw: pitch, pitch: validYaw, displayOrientation: .portrait)
    }
    #expect(throws: GyroCalibrationError.invalidOrientation) {
        try AxisCalibration.derive(yaw: validYaw, pitch: pitch, displayOrientation: .unknown)
    }
}
~~~

- [ ] **Step 2: Implementar geometría y calibración**

Normalizar cuaterniones solo si todos sus componentes son finitos y la norma original está en 0,9...1,1. rotationVector() normaliza el signo del cuaternión y devuelve el vector eje×ángulo en radianes, con una rama estable para ángulos cercanos a cero. derive calcula qFin × conjugado(qInicio), obtiene el vector de rotación de cada ensayo, comprueba ambos ángulos observados ≥1,5°, comprueba que yaw/pitch están a >80° y <100°, alinea sus signos con el delta Osmo YXZ y calcula roll = normalize(yaw × pitch). El inicializador público vuelve a validar finitud, longitud unitaria y ortogonalidad; no acepta una calibración manualmente malformada. La implementación Codable custom aplica esa misma validación al decodificar UserDefaults/JSONL; nunca sintetizar un decoder que acepte ejes inválidos.

- [ ] **Step 3: Registrar el target puro y comprobarlo**

Package.swift añade GimbalMotionKit como producto y target con dependencia solo de GimbalKit; el test target GimbalMotionKitTests depende de GimbalKit y GimbalMotionKit. Comando futuro: swift test --filter AxisCalibrationTests. Expected: las tres orientaciones producen los ejes conocidos y los casos degenerados fallan con GyroCalibrationError tipado. No se importa CoreMotion en este target.

---

### Task 2 — Fusión absoluta/relativa, anclaje y fiabilidad

**Files:**
- Create: Sources/GimbalMotionKit/PoseReliability.swift, FusedPoseEstimator.swift
- Test: Tests/GimbalMotionKitTests/FusedPoseEstimatorTests.swift

**Interfaces:**
- Consumes: AxisCalibration, GyroSample y PoseSample de Osmo. El tiempo entregado a los métodos es monotónico en segundos; no comparar CMDeviceMotion.timestamp con Date.
- Produces: public enum PoseReliabilityFailure: String, Sendable, Codable, Equatable { case missingCalibration, missingAnchor, sourceUnavailable, staleGyro, oldAnchor, anchorDiscrepancy, invalidSample, timestampRegression, timestampGap, orientationChanged }.
- Produces: public struct PoseReliability: Sendable, Equatable, Codable { public let isCalibrated: Bool; public let isAnchored: Bool; public let gyroAgeSeconds: Double?; public let anchorAgeSeconds: Double?; public let meanReanchorErrorDegrees: Double?; public let maxReanchorErrorDegrees: Double?; public let failure: PoseReliabilityFailure?; public init(isCalibrated: Bool, isAnchored: Bool, gyroAgeSeconds: Double?, anchorAgeSeconds: Double?, meanReanchorErrorDegrees: Double?, maxReanchorErrorDegrees: Double?, failure: PoseReliabilityFailure?); public var isReliable: Bool }.
- isReliable solo es true si failure == nil, isCalibrated, isAnchored, gyroAgeSeconds está en [0, 0,20), anchorAgeSeconds está en [0, 20] y maxReanchorErrorDegrees es nil o ≤3. El estimador publica .oldAnchor al superar 20 s mientras detecta movimiento; el gate de navegación rápida también rechaza conservadoramente un ancla vieja en reposo.
- Produces: public struct FusedPoseEstimator: Sendable { public init(calibration: AxisCalibration? = nil, displayOrientation: DisplayOrientation = .portrait); public mutating func setCalibration(_ calibration: AxisCalibration?); public mutating func setDisplayOrientation(_ orientation: DisplayOrientation); public mutating func noteMotion(at time: TimeInterval); public mutating func ingestGyro(_ sample: GyroSample, at time: TimeInterval) -> Pose?; public mutating func ingestOsmo(_ sample: PoseSample, at time: TimeInterval) -> PoseReliability; public func currentPose(at time: TimeInterval) -> Pose?; public func reliability(at time: TimeInterval) -> PoseReliability }.

- [ ] **Step 1: Escribir las pruebas rojas**

En FusedPoseEstimatorTests.swift, crear una calibración identidad con los fixtures de Task 1 y probar el protocolo temporal completo. Los helpers crean muestras quietas a 100 Hz y Osmo con secuencia creciente; no usar Task.sleep.

~~~swift
import Foundation
import Testing
import GimbalKit
import GimbalMotionKit

private func quietGyro(_ estimator: inout FusedPoseEstimator, from: Double, through: Double,
                       yawDegrees: Double = 0) {
    var t = from
    while t <= through + 1e-9 {
        let sample = GyroTestFixtures.sample(MotionVector3(x: 0, y: 1, z: 0), yawDegrees, t)
        _ = estimator.ingestGyro(sample, at: t)
        t += 0.01
    }
}

private func anchoredEstimator() -> FusedPoseEstimator {
    let calibration = try! AxisCalibration(
        yawAxisInPhone: MotionVector3(x: 0, y: 1, z: 0),
        pitchAxisInPhone: MotionVector3(x: 1, y: 0, z: 0),
        displayOrientation: .portrait
    )
    return FusedPoseEstimator(calibration: calibration)
}

@Test func anchorsOnlyAfterTwoNewQuietOsmoSamplesAndTwoSecondsWithoutMotion() {
    var estimator = anchoredEstimator()
    estimator.noteMotion(at: 0)
    quietGyro(&estimator, from: 0, through: 2.2)
    let first = estimator.ingestOsmo(GyroTestFixtures.pose(10, 4, 1), at: 2.0)
    #expect(!first.isAnchored)
    let second = estimator.ingestOsmo(GyroTestFixtures.pose(10, 4, 2), at: 2.2)
    #expect(second.isAnchored)
    #expect(second.isReliable)
    #expect(abs(estimator.currentPose(at: 2.2)!.yaw - 10) < 0.01)
    #expect(abs(estimator.currentPose(at: 2.2)!.pitch - 4) < 0.01)
}

@Test func samplesDuringMotionNeverReplaceTheAbsoluteAnchor() {
    var estimator = anchoredEstimator()
    estimator.noteMotion(at: 0)
    quietGyro(&estimator, from: 0, through: 3)
    _ = estimator.ingestOsmo(GyroTestFixtures.pose(0, 0, 1), at: 2)
    _ = estimator.ingestOsmo(GyroTestFixtures.pose(0, 0, 2), at: 3)
    estimator.noteMotion(at: 3.1)
    quietGyro(&estimator, from: 3.1, through: 4.9, yawDegrees: 5)
    _ = estimator.ingestOsmo(GyroTestFixtures.pose(0, 0, 3), at: 4.7)
    let state = estimator.ingestOsmo(GyroTestFixtures.pose(0, 0, 4), at: 4.9)
    #expect(state.isAnchored)
    #expect(state.anchorAgeSeconds ?? 0 > 1.8)
    #expect(estimator.currentPose(at: 4.9)!.yaw > 4)
}

@Test func handTurnAndLargeReanchorErrorMakeTheSourceUnreliable() {
    var estimator = anchoredEstimator()
    estimator.noteMotion(at: 0)
    quietGyro(&estimator, from: 0, through: 3)
    _ = estimator.ingestOsmo(GyroTestFixtures.pose(0, 0, 1), at: 2)
    _ = estimator.ingestOsmo(GyroTestFixtures.pose(0, 0, 2), at: 3)
    quietGyro(&estimator, from: 3.01, through: 6, yawDegrees: 6)
    _ = estimator.ingestOsmo(GyroTestFixtures.pose(0, 0, 3), at: 5)
    let state = estimator.ingestOsmo(GyroTestFixtures.pose(0, 0, 4), at: 6)
    #expect(!state.isReliable)
    #expect(state.failure == .anchorDiscrepancy)
    #expect(state.maxReanchorErrorDegrees ?? 0 > 3)
}

@Test func oldAnchorMutedGyroInvalidNumbersTimestampJumpsAndOrientationChangeDegrade() {
    var estimator = anchoredEstimator()
    estimator.noteMotion(at: 0)
    quietGyro(&estimator, from: 0, through: 3)
    _ = estimator.ingestOsmo(GyroTestFixtures.pose(0, 0, 1), at: 2)
    _ = estimator.ingestOsmo(GyroTestFixtures.pose(0, 0, 2), at: 3)
    #expect(estimator.reliability(at: 3.199).isReliable)
    #expect(estimator.reliability(at: 3.201).failure == .staleGyro)
    estimator.noteMotion(at: 4)
    quietGyro(&estimator, from: 3.01, through: 24)
    #expect(estimator.reliability(at: 24).failure == .oldAnchor)

    let regression = GyroSample(attitude: MotionQuaternion(x: 0, y: 0, z: 0, w: 1), timestamp: 2)
    _ = estimator.ingestGyro(regression, at: 24)
    let gap = GyroSample(attitude: MotionQuaternion(x: .nan, y: 0, z: 0, w: 1), timestamp: 30)
    _ = estimator.ingestGyro(gap, at: 30)
    #expect(!estimator.reliability(at: 30).isReliable)

    estimator.setDisplayOrientation(.landscapeRight)
    #expect(estimator.reliability(at: 30).failure == .orientationChanged)
}
~~~

- [ ] **Step 2: Implementar el estimador**

El estimador conserva la última actitud gyro, el ancla (actitud gyro, Pose Osmo y timestamp monotónico), secuencias Osmo ya consumidas, el último STOP/pulso, quietud medida, y una ventana acotada de errores de reanclaje. Los ejes calibrados proyectan el vector de rotación relativo sobre yaw/pitch; roll se calcula con el tercer eje. En yaw, el delta de error usa el arco mínimo de −180°...180°.

Una muestra Osmo solo cuenta si su sequence es mayor. El contador de dos muestras empieza de nuevo con noteMotion. El anclaje requiere ≥2 s desde noteMotion, dos secuencias nuevas, variación Osmo ≤0,3° y velocidad gyro <0,2°/s durante ≥0,25 s. El primer ancla fija el offset; cada ancla posterior primero compara error y actualiza métricas. Si el error máximo de yaw/pitch supera 3°, guardar failure=.anchorDiscrepancy, invalidar calibration y conservar la última pose absoluta; no sustituir offset. Si el ancla supera 20 s mientras hay movimiento, reliability devuelve oldAnchor. Un timestamp gyro repetido/regresivo o salto >0,20 s marca fallo; muestras no finitas nunca actualizan estado.

- [ ] **Step 3: Comprobar casos temporales y límites**

Comando futuro: swift test --filter FusedPoseEstimatorTests. Añadir los tests del ancla vieja con movimiento, error de reanclaje, yaw circular cerca de ±180°, muestra Osmo repetida, giro de teléfono a mano, quaternion de norma inválida y ausencia de ancla si el gimbal se mueve. El test no considera “nueva” una lectura solo porque receivedAt se actualice: exige sequence nueva.

---

### Task 3 — FusedPoseDevice y giroscopio simulado

**Files:**
- Create: Sources/GimbalMotionKit/FusedPoseDevice.swift, Sources/GimbalKitSim/SimulatedGyroSource.swift
- Modify: Package.swift (GimbalKitSim depende también de GimbalMotionKit; target de pruebas nuevo)
- Create: Tests/GimbalMotionKitTests/FusedPoseDeviceTests.swift

**Interfaces:**
- Consumes: cualquier PoseFeedbackDevice y GyroSource; RuntimeClock y reloj monotónico inyectables.
- Produces: public actor FusedPoseDevice: PoseFeedbackDevice { public nonisolated let capabilities: Capabilities; public init(base: any PoseFeedbackDevice, source: any GyroSource, clock: RuntimeClock = .live, monotonicNow: @escaping @Sendable () -> TimeInterval, calibration: AxisCalibration? = nil, displayOrientation: DisplayOrientation = .portrait); public func start() async throws; public func stop() async; public func setCalibration(_ calibration: AxisCalibration?); public func setDisplayOrientation(_ orientation: DisplayOrientation); public func requireReliablePose(_ required: Bool); public func reliability() -> PoseReliability; public func latestGyroSample() -> GyroSample?; public func poseSample() async -> PoseSample?; public func currentPose() async -> Pose?; public func send(_ command: MoveCommand) async throws }.
- Produces: public actor SimulatedGyroSource: GyroSource { public init(); public func start() async throws -> AsyncStream<GyroSample>; public func stop() async; public func updateDisplayOrientation(_ orientation: DisplayOrientation) async; public func emit(_ sample: GyroSample) }.
- El adapter envuelve OMDevice, reenvía capabilities y cada MoveCommand exactamente una vez; al recibir cada gyro válido consulta el último PoseSample Osmo, lo ingiere si sequence cambió y publica la pose fusión si está anclada/fiable.

- [ ] **Step 1: Escribir las pruebas rojas**

FusedPoseDeviceTests construye un OMDevice falso y una fuente simulada. El test comprueba que nuevas muestras gyro dan sequence y receivedAt nuevos, y que una fuente sin calibración sigue entregando el timestamp original de Osmo en modo lento. El modo rápido exige pose fiable y, al perder muestras, devuelve nil en lugar de disfrazar la última muestra como nueva.

~~~swift
import Foundation
import Testing
import GimbalKit
import GimbalMotionKit
import GimbalKitSim

private actor MotionFeedbackFake: PoseFeedbackDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    private var sample = PoseSample(pose: Pose(yaw: 5), receivedAt: Date(timeIntervalSince1970: 10), sequence: 1)
    private(set) var sent: [MoveCommand] = []
    func poseSample() -> PoseSample? { sample }
    func currentPose() -> Pose? { sample.pose }
    func send(_ command: MoveCommand) async throws { sent.append(command) }
    func replace(_ value: PoseSample) { sample = value }
}

private final class MonotonicBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 10
    func now() -> Double { lock.withLock { value } }
    func set(_ newValue: Double) { lock.withLock { value = newValue } }
}

@Test func slowPoseFallsBackToTheOriginalOsmoSampleWithoutRefreshingItsAge() async throws {
    let base = MotionFeedbackFake()
    let source = SimulatedGyroSource()
    let clock = MonotonicBox()
    let fused = FusedPoseDevice(base: base, source: source, monotonicNow: { clock.now() })
    try await fused.start()
    let original = await base.poseSample()!
    let fallback = await fused.poseSample()
    #expect(fallback == original)
    #expect(await fused.reliability().failure == .missingCalibration)
    await fused.stop()
}

@Test func fastPoseRequiresReliableGyroAndForwardsStopExactlyOnce() async throws {
    let base = MotionFeedbackFake()
    let source = SimulatedGyroSource()
    let clock = MonotonicBox()
    let fused = FusedPoseDevice(base: base, source: source, monotonicNow: { clock.now() })
    try await fused.start()
    await fused.requireReliablePose(true)
    #expect(await fused.poseSample() == nil)
    try await fused.send(.stop)
    #expect(await base.sent == [.stop])
    await fused.stop()
}
~~~

- [ ] **Step 2: Implementar la envoltura y fuente de prueba**

FusedPoseDevice inicia/cancela un único consumidor de GyroSource. Si start de la fuente falla, registra la causa y permanece operativo en lento con la telemetría base; un sensor no disponible nunca hace fallar la conexión. En cada muestra conserva el último gyro y Osmo; llama a noteMotion antes de reenviar speed o stop al dispositivo base. Si la estimación es fiable, incrementa sequence y crea PoseSample(pose:receivedAt:clock.now(),sequence:next) por cada gyro. Si requireReliablePose está activo y la fuente deja de ser fiable, poseSample devuelve nil en cada consulta (incluida la segunda consulta del controlador dentro de navigationPulse). En modo lento devuelve la PoseSample Osmo sin alterar fecha ni secuencia. stop cancela consumidor y detiene la fuente; no envía STOP por su cuenta.

SimulatedGyroSource crea una AsyncStream nueva en start, emite solo muestras solicitadas por el test y finish/cierra al detenerse. Debe permitir reordenar o dejar de emitir para probar regresión y silencio. No usa timers reales.

- [ ] **Step 3: Integrar el simulador sin ciclos**

GimbalKitSim depende de GimbalKit y GimbalMotionKit; GimbalMotionKit solo depende de GimbalKit. El testTarget GimbalMotionKitTests depende de GimbalKit, GimbalMotionKit y GimbalKitSim, y cubre rotaciones yaw/pitch conocidas, deriva, ruido, 0,7 s de pose Osmo retardada, jitter, pérdida y recuperación de muestras. Package.swift añade la dependencia de GimbalMotionKit a GimbalKitSim; no hay ciclo. Comando futuro: swift test --filter FusedPoseDeviceTests.

---

### Task 4 — Perfil rápido aditivo en GotoNavigator

**Files:**
- Modify: Sources/GimbalKit/NavigationSafety.swift, Sources/GimbalKit/GotoNavigator.swift
- Create: Tests/GimbalKitTests/NavigationProfileTests.swift

**Interfaces:**
- Preserves: NavigationLimits.init() -> NavigationLimits conserva los diez valores actuales; GotoNavigator.init(controller: GimbalController, clock: RuntimeClock = .live) mantiene el comportamiento idéntico.
- Produces: public static let fast: NavigationLimits; GotoNavigator.init(controller: GimbalController, clock: RuntimeClock = .live, limits: NavigationLimits = NavigationLimits()).
- Profile fast exacto: maxSpeed 6, gain 1, deadband 1,5, pulseSeconds 0,20, brakingSeconds 0,35, physicalGain 1,25, margin 0,5, settleSeconds 0,25, staleSeconds 0,20, timeoutSeconds 25.
- GotoNavigator valida age = clock.now() − sample.receivedAt justo después de cada `navigationContext` y antes de decidir llegada o pulso, usando limits.staleSeconds. El lento conserva 1,5 s; el rápido exige 0,20 s. En fast, el FusedPoseDevice aplica además el mismo umbral dentro de `poseSample()` para cubrir la lectura interna que GimbalController hace al emitir cada pulso.

- [ ] **Step 1: Añadir pruebas rojas de compatibilidad y envolvente**

~~~swift
import Foundation
import Testing
import GimbalKit
import GimbalKitSim

@Test func defaultNavigationLimitsAndNavigatorInitKeepTheExistingProfile() {
    let slow = NavigationLimits()
    #expect(slow.maxSpeed == 6)
    #expect(slow.gain == 1)
    #expect(slow.deadband == 2)
    #expect(slow.pulseSeconds == 0.30)
    #expect(slow.brakingSeconds == 0.20)
    #expect(slow.physicalGain == 1.25)
    #expect(slow.margin == 0.5)
    #expect(slow.settleSeconds == 0.90)
    #expect(slow.staleSeconds == 1.5)
    #expect(slow.timeoutSeconds == 25)
    let fast = NavigationLimits.fast
    #expect(fast.maxSpeed == 6)
    #expect(fast.gain == 1)
    #expect(fast.deadband == 1.5)
    #expect(fast.pulseSeconds == 0.20)
    #expect(fast.brakingSeconds == 0.35)
    #expect(fast.physicalGain == 1.25)
    #expect(fast.margin == 0.5)
    #expect(fast.settleSeconds == 0.25)
    #expect(fast.staleSeconds == 0.20)
    #expect(fast.timeoutSeconds == 25)
}

@Test func fastSafetyEnvelopeIncludesGyroAgeAndMeasuredBrakeBound() throws {
    let zone = Zone(name: "permitida", yaw: -10...10, pitch: -10...10)
    let forbidden = Zone(name: "no", yaw: 8...9, pitch: -2...2, forbidden: true)
    #expect(throws: NavigationError.unsafePath) {
        try NavigationSafety.check(pose: Pose(yaw: 5), velocity: Pose(yaw: 6),
                                   zone: zone, forbidden: [forbidden], limits: .fast)
    }
    try NavigationSafety.check(pose: Pose(yaw: 0), velocity: Pose(yaw: 6),
                               zone: zone, forbidden: [], limits: .fast)
}

@Test func fastNavigatorRejectsPoseOlderThanItsOwnFreshnessLimit() async throws {
    let manual = ManualClock()
    let safe = Zone(name: "safe", yaw: -10...10, pitch: -10...10)
    let device = LaggedPoseDevice(clock: manual)
    let controller = GimbalController(
        device: device,
        policy: SafetyPolicy(maxSpeed: 6, maxLeaseSeconds: 30, deadmanSeconds: 0.5, zones: [safe]),
        now: { manual.now() }
    )
    let timing = RuntimeClock(now: { manual.now() }, sleep: { _ in
        try Task.checkCancellation()
        await Task.yield()
    })
    let lease = try await controller.requestLease(source: .agent("profile-test"), zone: "safe", seconds: 30)
    manual.advance(0.201)
    let navigator = GotoNavigator(controller: controller, clock: timing, limits: .fast)
    await #expect(throws: NavigationError.stalePose) {
        try await navigator.go(to: "safe", source: .agent("profile-test"), lease: lease)
    }
}
~~~

- [ ] **Step 2: Añadir el parámetro sin alterar el default**

NavigationLimits recibe un inicializador privado con todos sus campos constantes; public init() delega los números ya presentes, sin cambios. fast compone el horizonte de 0,20 s de pulso + 0,35 s de cota combinada de edad gyro/frenado; NavigationSafety.check ya multiplica ese horizonte por physicalGain, calcula el barrido y margen y rechaza salida de zona/solape prohibido. GotoNavigator guarda el limits recibido y, antes de decidir deadband o emitir un pulso, comprueba frescura por ese perfil. No tocar GimbalController: su máximo/política independiente de 6°/s continúa siendo otro guardia.

- [ ] **Step 3: Ejecutar la suite focalizada y preservar consumidores**

Comando futuro: swift test --filter NavigationProfileTests y swift test --filter GotoNavigatorTests. No editar las pruebas actuales. Buscar todos los inicializadores GotoNavigator del repo, incluidos Sources/GimbalLabSupport/LabModel.swift y LabHardwareTestRunner.swift; el argumento opcional no rompe sus llamadas. Verificar que el valor por defecto produce el mismo deadline, deadband, cadencia y asentamiento.

---

### Task 5 — HostRuntime, calibración guiada y degradación automática

**Files:**
- Create: Sources/GimbalHostSupport/GyroCalibrationRunner.swift, Tests/GimbalHostSupportTests/GyroFastNavigationTests.swift
- Modify: Package.swift, Sources/GimbalHostSupport/HostRuntime.swift, PhoneHostEnvironment.swift

**Interfaces:**
- Preserves source compatibility by extending the existing single initializer (do not retain a duplicate overload with all-defaulted arguments): public init(makeLink: @escaping @Sendable () -> any HostLink, store: ZoneStore, clock: RuntimeClock = .live, motionStopCounter: MotionStopCounter = MotionStopCounter(), gyroSource: (any GyroSource)? = nil, initialCalibration: AxisCalibration? = nil, monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }).
- Produces: public enum HostNavigationProfile: Sendable, Equatable { case standard, gyroFast }.
- Preserves: public func look(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult; public func look(zone: String, leaseSeconds: Double, stopToken: UInt64?) async throws -> GimbalLookResult.
- Produces: public func look(zone: String, leaseSeconds: Double, stopToken: UInt64?, profile: HostNavigationProfile) async throws -> GimbalLookResult; las firmas MCP y look(zone:leaseSeconds:stopToken:) delegan al perfil estándar.
- Produces: public func gyroReliability() -> PoseReliability?; public func installGyroCalibration(_ calibration: AxisCalibration?); public func calibrateGyroscope(displayOrientation: DisplayOrientation) async throws -> AxisCalibration.
- Produces: public func updateDisplayOrientation(_ orientation: DisplayOrientation).
- Produces: internal struct GyroCalibrationRunner: Sendable { init(controller: GimbalController, osmo: any PoseFeedbackDevice, fused: FusedPoseDevice, motionStopCounter: MotionStopCounter, clock: RuntimeClock, monotonicNow: @escaping @Sendable () -> TimeInterval); func run(zones: [Zone], rigID: UUID, currentRigID: @escaping @Sendable () async -> UUID?, displayOrientation: DisplayOrientation) async throws -> AxisCalibration }.
- Produces: internal enum GyroCalibrationRunError: Error, Sendable, Equatable { case noSafeMargin, referenceRequired, leaseBusy, stopped, rigChanged, unstableBase, invalidTrial }.
- PhoneHostEnvironment preserves source compatibility by extending its single existing initializer (no duplicate all-defaulted overload): public init(makeLink: @escaping @Sendable () -> any HostLink, store: ZoneStore, clock: RuntimeClock = .live, gyroSourceSlot: GyroSourceSlot? = nil, initialCalibration: AxisCalibration? = nil, monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }).
- PhoneHostEnvironment exposes public let gyroSourceSlot: GyroSourceSlot?; public func installGyroSource(_ source: any GyroSource) async; public func updateDisplayOrientation(_ orientation: DisplayOrientation) async. The iOS `shared` constructs one slot and passes that same slot to HostRuntime; a custom/default environment without a slot keeps the current non-fused path.
- GimbalMotionKit es opcional en HostRuntime. Sin fuente gyro, rig, controlador, navigator, status y navegación son los actuales. Con fuente, el controller recibe FusedPoseDevice que reenvía órdenes al mismo OMDevice.

- [ ] **Step 1: Escribir pruebas rojas del host**

Añadir en el fichero nuevo GyroFastNavigationTests.swift. FakeLink, StepSleeper y eventually son fixtures internos existentes del mismo target de tests; el test define solo su reloj monotónico y su detector de frames, con nombres propios. La zona tiene centro yaw=4° para obligar una orden SPEED; el feeder produce telemetría y gyro a 100 Hz con reloj manual.

~~~swift
import Foundation
import Testing
import GimbalKit
import GimbalKitSim
import GimbalMotionKit
@testable import GimbalHostSupport

private final class FastTestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { value } }
    func set(_ value: TimeInterval) { lock.withLock { self.value = value } }
}

private func fastTestCalibration() throws -> AxisCalibration {
    try AxisCalibration(yawAxisInPhone: MotionVector3(x: 0, y: 1, z: 0),
                        pitchAxisInPhone: MotionVector3(x: 1, y: 0, z: 0),
                        displayOrientation: .portrait)
}

private func fastTestSample(_ time: TimeInterval) -> GyroSample {
    GyroSample(attitude: MotionQuaternion(x: 0, y: 0, z: 0, w: 1), timestamp: time)
}

private func hasNonzeroSpeedFrame(_ frames: [[UInt8]]) -> Bool {
    frames.contains { frame in
        guard frame.count >= 17, frame[10] == 0x0C else { return false }
        return frame[11...16].contains { $0 != 0 }
    }
}

@Test func stopDuringFastLookCannotEmitSpeedAfterStop() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = FakeLink()
    let source = SimulatedGyroSource()
    let sleeper = StepSleeper()
    let runtimeClock = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let motionTime = FastTestMonotonicClock()
    let store = ZoneStore(url: root.appendingPathComponent("zones.json"))
    try await store.save([Zone(name: "mesa", yaw: -6...14, pitch: -10...10)])
    let runtime = HostRuntime(
        makeLink: { link },
        store: store,
        clock: runtimeClock,
        gyroSource: source,
        initialCalibration: try fastTestCalibration(),
        monotonicNow: { motionTime.now() }
    )
    try await runtime.start()
    #expect(await eventually { (try? await runtime.status().connected) == true })
    await link.attitude()
    #expect(await eventually { (try? await runtime.status().pose) != nil })
    let reference = try await runtime.prepareReference()
    try await runtime.confirmReference(reference)

    let feeder = Task {
        for index in 0..<20_000 {
            guard !Task.isCancelled else { return }
            let time = Double(index) / 100
            motionTime.set(time)
            await link.attitude()
            await source.emit(fastTestSample(time))
            await sleeper.advance(0.01)
            await Task.yield()
        }
    }
    #expect(await eventually { await runtime.gyroReliability()?.isReliable == true })
    let token = runtime.motionStopCounter.read()
    let look = Task {
        try await runtime.look(zone: "mesa", leaseSeconds: 30, stopToken: token, profile: .gyroFast)
    }
    #expect(await eventually { hasNonzeroSpeedFrame(await link.writes) })
    await runtime.humanStop()
    let writesAtStop = await link.writes
    feeder.cancel()
    await feeder.value
    _ = await look.result
    #expect(!hasNonzeroSpeedFrame(Array((await link.writes).dropFirst(writesAtStop.count))))
    #expect(try await runtime.status().lease == nil)
    await runtime.shutdown()
}
~~~

El mismo fichero añade el test de downgrade con fuente que deja de emitir: empezar fiable, pausar SimulatedGyroSource, avanzar reloj >0,20 s, alimentar solo telemetría Osmo y comprobar que la misma mirada termina con el navigator estándar. Añadir casos separados para oldAnchor y anchorDiscrepancy; el test STOP usa la instantánea posterior a humanStop y espera la terminación de look antes de asertar.

- [ ] **Step 2: Conectar fusión sin cambiar el driver**

HostRuntime crea OMDevice y, si recibió GyroSource, FusedPoseDevice(base: OMDevice, ...). El Rig conserva el OMDevice para battery/shutdown y una referencia PoseFeedbackDevice para status/freshRig. El controller recibe el wrapper; send reenvía una vez al OMDevice. Al desconectar, Runtime detiene fusion y el driver como ahora. status y prepareZone usan la mejor pose absoluta disponible; el fallback lento devuelve la muestra Osmo original.

- [ ] **Step 3: Implementar calibración serializada y cancelable**

GyroCalibrationRunner toma token MotionStopCounter antes de la primera espera, verifica conexión/referencia, ausencia de lease, quietud y una zona permitida que contenga todo el recorrido y margen de frenado. Para cada eje guarda GyroSample y PoseSample antes, calcula una zona temporal que incluye pose inicial, objetivo a 5° (la distancia ejecutada es ~3° al considerar el deadband lento de 2°) y toda la envolvente NavigationSafety del pulso, dentro de los límites permitidos y sin solapar zonas prohibidas; conserva todas las zonas almacenadas. HostRuntime marca `editing = true` antes de invocar el runner y mantiene look/delete/reference/calibración mutuamente excluyentes mientras se reemplazan las zonas del controller. Pide lease no privilegiado `.agent("gyro-calibration")`, ejecuta GotoNavigator lento y captura muestras posteriores al asentamiento. Dos ensayos no exceden 6°/s. La sustitución se aplica solo a `controller.replaceZones`; las zonas temporales nunca se escriben en ZoneStore y la lista guardada se restaura en success, error, cancelación o STOP. Tras cada await verifica token y rigID; un STOP termina el ensayo, impide iniciar el siguiente eje y restaura la política antes de liberar `editing`.

Solo al obtener dos trials válidos se llama AxisCalibration.derive. HostRuntime instala el resultado en el FusedPoseDevice y devuelve el Codable a PhoneHostModel para persistirlo. La calibración guardada se invalida al cambiar orientación, al fallar validación periódica o si el rig cambia de sesión.

- [ ] **Step 4: Implementar downgrade rápido→lento**

Los perfiles son dos GotoNavigator del mismo controller, uno estándar y otro con NavigationLimits.fast. Antes de solicitar fast, HostRuntime vuelve a comprobar fiabilidad, rig y token; si ya no es fiable, selecciona standard antes de crear lease. Si es fiable, activa requireReliablePose(true). El wrapper oculta la muestra a cada llamada de `poseSample()` cuando gyro deja de ser fiable; así cubre también la segunda lectura que GimbalController hace dentro de `navigationPulse`. Si `go` termina con `SafetyViolation.poseUnavailable` o `NavigationError.stalePose`, HostRuntime lo trata como degradación solo si la fiabilidad actual ya es falsa: `go` ya ejecutó su cleanup/STOP y liberó el lease. Luego comprueba cancelación, token y rigID antes de desactivar requireReliablePose, adquirir lease nuevo y reanudar la misma zona con el navigator estándar. STOP/cancelación/rig cambiado abortan y nunca llegan al segundo lease; otros errores se propagan sin fallback. No se crea tarea de navegación paralela. Antes de publicar éxito comprueba token/rig otra vez.

- [ ] **Step 5: Probar downgrade y STOP en cada frontera**

Añadir tests deterministas para ancla >20 s, silencio gyro, discrepancia >3°, movimiento físico del teléfono, calibración invalidada por orientación, lease liberado antes del nuevo, STOP durante el primer perfil y STOP justo entre liberar y volver a pedir lease. En la última carrera, no debe aparecer un SPEED no nulo después del snapshot posterior a humanStop. Probar también que el MCP y PhoneWatchRuntime conservan las llamadas antiguas y nunca reciben .gyroFast.

- [ ] **Step 6: Comprobar módulos**

Package.swift añade GimbalMotionKit a las dependencias directas de GimbalHostSupport y GimbalHostSupportTests. Comandos futuros: swift test --filter GyroFastNavigationTests y swift build. El target de host sigue compilando para macOS/iOS sin cambiar GimbalController, OMDevice, PhoneWatchService o MCP. La suite global conserva los 193 tests existentes sin modificaciones; omitir los cuatro loopback solo en la pasada sandbox.

---

### Task 6 — CoreMotion y ajustes de navegación en GimbalPhone

**Files:**
- Create: Apps/GimbalPhone/CoreMotionGyroSource.swift, GyroSettingsView.swift, Apps/Tests/GyroSettingsTests.swift
- Modify: Apps/GimbalPhone/GimbalPhoneApp.swift, PhoneHomeView.swift, Apps/project.yml, Sources/GimbalHostSupport/PhoneHostModel.swift, PhoneHostEnvironment.swift

**Interfaces:**
- CoreMotionGyroSource: public actor CoreMotionGyroSource: GyroSource { public init(sampleRate: Double = 100); public func start() async throws -> AsyncStream<GyroSample>; public func stop() async; public func updateDisplayOrientation(_ orientation: DisplayOrientation) async }.
- PhoneHostModel mantiene `look(zone:)` y el init de test existente `init(environment:haptics:lookAction:)` con closure `@Sendable (String, UInt64) async throws -> GimbalLookResult`; añade `init(environment:haptics:profiledLookAction:)` con closure `@Sendable (String, UInt64, HostNavigationProfile) async throws -> GimbalLookResult`, `gyroReliability: PoseReliability?`, `fastNavigationEnabled: Bool`, `calibration: AxisCalibration?`, `calibrateGyroscope() async throws`, `setFastNavigationEnabled(_ enabled: Bool)`, y `updateDisplayOrientation(_ orientation: DisplayOrientation) async`.
- Produces: public nonisolated static func navigationProfile(fastNavigationEnabled: Bool, calibration: AxisCalibration?, reliability: PoseReliability?) -> HostNavigationProfile; solo devuelve .gyroFast si fastNavigationEnabled, calibration != nil y reliability?.isReliable == true.
- El seam interno de lookAction(zone:token:) sigue existiendo para las pruebas actuales; el nuevo seam profile-aware se añade con otra etiqueta, sin cambiar closures existentes.
- Apps/project.yml conserva info.path y todas las propiedades actuales; añade NSMotionUsageDescription y el producto GimbalMotionKit necesario. Package.swift añade GimbalMotionKit a GimbalAppTests.

- [ ] **Step 1: Probar selección de perfil sin CoreMotion**

Añadir una prueba pura de selección sin inicializar HostRuntime ni CoreMotion. La preferencia apagada, ausencia de calibración o cualquier fiabilidad degradada devuelven `.standard`; calibración más preferencia activada y fiabilidad vigente devuelven `.gyroFast`. La integración que pasa el perfil y conserva el token STOP queda cubierta por GyroFastNavigationTests y los tests de PhoneHostModel existentes permanecen intactos.

~~~swift
import Testing
import GimbalKit
import GimbalMotionKit
import GimbalHostSupport

@Test func fastPreferenceRequiresCalibrationAndReliabilityAtDispatch() {
    let calibration = try! AxisCalibration(
        yawAxisInPhone: MotionVector3(x: 0, y: 1, z: 0),
        pitchAxisInPhone: MotionVector3(x: 1, y: 0, z: 0),
        displayOrientation: .portrait
    )
    let reliable = PoseReliability(isCalibrated: true, isAnchored: true,
        gyroAgeSeconds: 0.01, anchorAgeSeconds: 3, meanReanchorErrorDegrees: 0.4,
        maxReanchorErrorDegrees: 1.2, failure: nil)
    let stale = PoseReliability(isCalibrated: true, isAnchored: true,
        gyroAgeSeconds: 0.21, anchorAgeSeconds: 3, meanReanchorErrorDegrees: 0.4,
        maxReanchorErrorDegrees: 1.2, failure: .staleGyro)
    #expect(PhoneHostModel.navigationProfile(fastNavigationEnabled: false,
        calibration: calibration, reliability: reliable) == .standard)
    #expect(PhoneHostModel.navigationProfile(fastNavigationEnabled: true,
        calibration: nil, reliability: reliable) == .standard)
    #expect(PhoneHostModel.navigationProfile(fastNavigationEnabled: true,
        calibration: calibration, reliability: stale) == .standard)
    #expect(PhoneHostModel.navigationProfile(fastNavigationEnabled: true,
        calibration: calibration, reliability: reliable) == .gyroFast)
}
~~~

- [ ] **Step 2: Implementar fuente CoreMotion aislada**

CMMotionManager usa el frame `.xArbitraryCorrectedZVertical` y entrega attitude quaternion (x,y,z,w) y timestamp monotónico a 100 Hz en una OperationQueue serial propia. Normalizar/validar antes de emitir GyroSample; un snapshot sincronizado de orientación etiqueta cada sample, sin acceder a SwiftUI/UI desde el callback. Si deviceMotion no está disponible, start lanza GyroSourceError.unavailable y HostRuntime conserva lento. stop detiene manager y termina stream. La orientación `.unknown` no calibra ni habilita rápido. La orientación de pantalla se actualiza desde el host iOS; si difiere de AxisCalibration.displayOrientation, invalidar calibración y ancla inmediatamente.

GimbalPhoneApp instala CoreMotionGyroSource en PhoneHostEnvironment.shared.gyroSourceSlot y carga/instala la calibración guardada antes de `model.start()`/`environment.start()`; PhoneHomeView observa UIWindowScene.interfaceOrientation y llama updateDisplayOrientation. El slot no requiere que GimbalKitIntents importe código de Apps/GimbalPhone y permite que el background arranque siga en lento si todavía no se instaló el sensor. Cada GyroSample lleva la orientación vigente y el estimador invalida si difiere. No se crean dos CMMotionManager ni dos HostRuntime.

- [ ] **Step 3: Añadir ajustes y métricas**

GyroSettingsView ofrece Calibrar giroscopio, muestra fases (reposo, yaw, reposo, pitch, validación), cancelación/parada, switch Navegación rápida apagado por defecto y métricas error medio/máximo, edad del ancla/gyro y razón del perfil lento. El switch se desactiva si falta calibración guardada. PhoneHostModel guarda AxisCalibration Codable en UserDefaults después de éxito, la restaura al conectar y la borra cuando se informa fallo de validación; la preferencia rápida se guarda como false por defecto y no puede activarse sin calibración. No muestra fiabilidad como verdadera si el último gyro tiene ≥0,20 s.

- [ ] **Step 4: Compilar iOS sin lanzar simulador**

Comprobar Info.plist generado mantiene el NSBluetoothAlwaysUsageDescription y UIBackgroundModes actuales junto con NSMotionUsageDescription. Ejecutar `xcodegen generate` y `xcodebuild -project Apps/GimbalKitApps.xcodeproj -scheme GimbalPhone -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`; no ejecutar, instalar ni lanzar un simulador. Ejecutar `swift test --filter GyroSettingsTests` en macOS.

---

### Task 7 — Diagnósticos compartidos con GimbalLab

**Files:**
- Create: Sources/GimbalMotionKit/GyroDiagnosticsLog.swift, Tests/GimbalKitDJITests/GyroDiagnosticsLabTests.swift
- Modify: Package.swift, Sources/GimbalHostSupport/PhoneHostModel.swift, Sources/GimbalLabSupport/LabModel.swift, Sources/GimbalLabMac/GimbalLabApp.swift

**Interfaces:**
- Produces: public struct GyroDiagnosticsRecord: Sendable, Equatable, Codable { public let version: Int; public let date: Date; public let monotonicTimestamp: TimeInterval; public let osmoPose: Pose?; public let fusedPose: Pose?; public let calibration: AxisCalibration?; public let reliability: PoseReliability; public init(version: Int = 1, date: Date, monotonicTimestamp: TimeInterval, osmoPose: Pose?, fusedPose: Pose?, calibration: AxisCalibration?, reliability: PoseReliability) }.
- Produces: public enum GyroDiagnosticsError: Error, Sendable, Equatable { case malformed, unsupportedVersion, tooLarge, nonFinite }.
- Produces: public enum GyroDiagnosticsLog { public static func encode(_ records: [GyroDiagnosticsRecord]) throws -> Data; public static func decode(_ data: Data) throws -> [GyroDiagnosticsRecord] }. encode uses UTF-8 JSON objects separated by LF with no required final terminator; decode accepts a single optional final LF or CRLF and rejects blank interior lines.
- PhoneHostModel.gyroDiagnosticsExport() throws -> Data exporta snapshots; LabModel añade `public private(set) var gyroDiagnostics: [GyroDiagnosticsRecord]` y `public func importGyroDiagnostics(_ data: Data) throws`; LabView muestra yaw/pitch Osmo frente a fused, error medio/máximo, edad del ancla, edad gyro y reason.

- [ ] **Step 1: Escribir prueba roja del formato**

~~~swift
import Foundation
import Testing
import GimbalKit
import GimbalMotionKit
import GimbalLabSupport

@MainActor
@Test func gyroDiagnosticsJSONLRoundTripsMetricsAndRejectsMalformedInput() throws {
    let reliability = PoseReliability(isCalibrated: true, isAnchored: true,
        gyroAgeSeconds: 0.01, anchorAgeSeconds: 3, meanReanchorErrorDegrees: 0.4,
        maxReanchorErrorDegrees: 1.2, failure: nil)
    let rows = [
        GyroDiagnosticsRecord(date: Date(timeIntervalSince1970: 10), monotonicTimestamp: 1,
            osmoPose: Pose(yaw: 2, pitch: 1), fusedPose: Pose(yaw: 2.2, pitch: 0.9),
            calibration: nil, reliability: reliability),
        GyroDiagnosticsRecord(date: Date(timeIntervalSince1970: 11), monotonicTimestamp: 2,
            osmoPose: Pose(yaw: 3, pitch: 1), fusedPose: nil, calibration: nil,
            reliability: PoseReliability(isCalibrated: true, isAnchored: false,
                gyroAgeSeconds: 0.21, anchorAgeSeconds: 21, meanReanchorErrorDegrees: 0.4,
                maxReanchorErrorDegrees: 3.4, failure: .oldAnchor))
    ]
    let data = try GyroDiagnosticsLog.encode(rows)
    #expect(try GyroDiagnosticsLog.decode(data) == rows)
    #expect(try GyroDiagnosticsLog.decode(Data()) == [])
    let jsonLines = String(decoding: data, as: UTF8.self)
    #expect(try GyroDiagnosticsLog.decode(Data((jsonLines + "\n").utf8)) == rows)
    let crlf = jsonLines.replacingOccurrences(of: "\n", with: "\r\n")
    #expect(try GyroDiagnosticsLog.decode(Data(crlf.utf8)) == rows)
    let splitLines = jsonLines.split(separator: "\n")
    let blankInterior = "\(splitLines[0])\n\n\(splitLines[1])\n"
    #expect(throws: GyroDiagnosticsError.malformed) {
        try GyroDiagnosticsLog.decode(Data(blankInterior.utf8))
    }
    #expect(throws: GyroDiagnosticsError.malformed) {
        try GyroDiagnosticsLog.decode(Data("{no-json}\n".utf8))
    }
    let unknownVersion = GyroDiagnosticsRecord(version: 99, date: Date(timeIntervalSince1970: 12),
        monotonicTimestamp: 3, osmoPose: nil, fusedPose: nil, calibration: nil,
        reliability: reliability)
    let unknownLine = try JSONEncoder().encode(unknownVersion) + Data([0x0A])
    #expect(throws: GyroDiagnosticsError.unsupportedVersion) {
        try GyroDiagnosticsLog.decode(unknownLine)
    }
    let oversized = Data(repeating: 0x20, count: 16 * 1024 * 1024 + 1)
    #expect(throws: GyroDiagnosticsError.tooLarge) {
        try GyroDiagnosticsLog.decode(oversized)
    }
    #expect(throws: GyroDiagnosticsError.tooLarge) {
        try GyroDiagnosticsLog.encode(Array(repeating: rows[0], count: 10_001))
    }
    let nonFinite = [GyroDiagnosticsRecord(date: Date(timeIntervalSince1970: 13),
        monotonicTimestamp: .infinity, osmoPose: nil, fusedPose: nil, calibration: nil,
        reliability: reliability)]
    #expect(throws: GyroDiagnosticsError.nonFinite) {
        try GyroDiagnosticsLog.encode(nonFinite)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let lab = LabModel(store: ZoneStore(url: root.appendingPathComponent("zones.json")))
    try lab.importGyroDiagnostics(data)
    #expect(lab.gyroDiagnostics == rows)
}
~~~

- [ ] **Step 2: Añadir exportación e importación**

PhoneHostModel registra snapshots mientras el panel de giroscopio está visible y permite exportar el JSONL desde el compartir de iOS. Cada fila incluye fecha, tiempo monotónico, pose Osmo, pose fusionada, calibración vigente y fiabilidad para que el barrido sea comparable en GimbalLab. GimbalLab recibe el archivo mediante fileImporter; no crea transporte de control ni modifica MCP/Watch/Bluetooth. LabModel conserva una ventana limitada a 10.000 filas y calcula sobre esos datos el máximo error y el estado actual. El archivo incluye solo datos cinemáticos, métricas y timestamps, nunca audio, ubicación, nombres de zonas o tokens.

Package.swift añade GimbalMotionKit a GimbalLabSupport, GimbalKitDJITests y GimbalAppTests; GimbalMotionKitTests y GimbalKitDJITests cubren el codec/import. Apps/project.yml añade el producto al target GimbalPhone.

- [ ] **Step 3: Verificar round-trip y lectura de laboratorio**

El decoder acepta un archivo vacío como cero filas, newline final y CRLF; rechaza línea interior vacía/malformada, versión desconocida, fecha/tiempo/pose/calibración no finitos y archivos sobre 16 MiB con GyroDiagnosticsError tipado. Limitar a 10.000 filas. Comando futuro: swift test --filter GyroDiagnosticsLabTests. Compilar GimbalLabMac; para la sesión física exportar desde iPhone y usar AirDrop/Files para importarlo en el Mac.

---

### Task 8 — MANUAL: calibrar y medir con Osmo e iPhone

**Files:**
- No requiere cambios adicionales. El log de diagnóstico se exporta desde GimbalPhone y se importa en GimbalLab.

- [ ] Con la Osmo en trípode, zona permitida amplia, zonas prohibidas fuera del recorrido y referencia humana confirmada, montar el iPhone en la posición que se vaya a usar. Abrir Calibrar giroscopio; confirmar los microgiros yaw/pitch de ~3° a ≤6°/s, las dos muestras Osmo posteriores y quietud ≥2 s. Repetir por separado con teléfono vertical, horizontal o invertido si se cambia el montaje.
- [ ] Barrer yaw y pitch de −20° a +20° y vuelta con la Osmo; comparar pose Osmo y fusionada, error medio/máximo y ancla. Repetir con la app indicando fuente gyro no fiable y confirmar que el perfil vuelve solo a lento.
- [ ] Con perfil rápido deshabilitado, girar el iPhone físicamente a mano sin mover la Osmo. Verificar discrepancia >3°, invalidación del ancla/calibración y cero órdenes posteriores al detectar el problema.
- [ ] Habilitar Navegación rápida después de calibrar. Medir cadencia, pulso real, frenado, asentamiento y exactitud; confirmar que la fuente recibe muestras cada <0,2 s y que la desviación permanece ≤3°. Interrumpir con STOP durante un pulso y durante el fallback; verificar STOP inmediato y que no aparece SPEED posterior.
- [ ] Dejar de entregar gyro >0,2 s, mantener movimiento con ancla >20 s y cambiar orientación de pantalla. En los tres casos confirmar caída automática a lento y métricas/causa visible. Restaurar el gyro y volver a calibrar cuando la calibración se haya invalidado.
- [ ] Medir el frenado físico. El perfil de este plan exige ≤0,25 s bajo el ensayo de referencia y usa 0,10 s de retraso gyro más margen en NavigationSafety.check. Si no se cumple, mantener fastNavigationEnabled apagado y recalcular la envolvente antes de otro ensayo.
- [ ] Exportar el JSONL del barrido y abrirlo en GimbalLab. Comparar yaw/pitch, error medio/máximo, edad del ancla y transiciones de fiabilidad. Guardar la medición del límite de seguridad antes de proponer un límite separado de 12°/s; esta tarea no cambia SafetyPolicy ni los guardias del controlador.

## Autorrevisión

- **Alcance:** siete tareas automáticas ordenadas y una manual final. Este documento define implementación futura; en esta redacción solo se crean el plan y su tabla de trampas.
- **Referencia:** Osmo conserva el cero mediante un ancla quieta posterior a STOP/pulso; no se fusiona una pose Osmo retrasada durante movimiento ni se reancla mientras hay movimiento.
- **Calibración:** dos rotaciones controladas generan ejes teléfono→gimbal; ortogonalidad 80°...100°, señal mínima 1,5°, roll por producto vectorial y orientación de pantalla vinculada a la calibración.
- **Fusión:** samples gyro monotónicos, secuencia/receivedAt renovados solo para muestras realmente fusionadas, métrica media/máxima, ancla ≤20 s durante movimiento, gyro <0,2 s, error de ancla ≤3°. NaN/Inf, secuencia/tiempo anómalos y sensor mudo degradan.
- **Fallback:** FusedPoseDevice retorna pose Osmo original en lento; rápido exige fiabilidad por muestra. HostRuntime espera a que el navegador rápido pare y libere antes de pedir lease lento; token y rig se revalidan a cada frontera await y antes del resultado.
- **STOP y política:** no se altera STOP, épocas, leases ni serialización del controlador. NavigationLimits() queda idéntico; fast continúa a 6°/s porque también existe un tope fijo de 6°/s en el GimbalController protegido.
- **Módulos:** GimbalMotionKit no conoce CoreMotion/Bluetooth. El sensor real y ajustes son iOS; GimbalLab recibe un log de datos mediante export/import, sin cambiar PhoneWatchService/MCP ni añadir transporte de control.
- **Pruebas:** rotación sintética en tres montajes; ancla quieta; degradación por edad, discrepancia y pérdida; giro físico a mano; STOP en fast y transición; retraso, ruido, drift, NaN/Inf y saltos de timestamp. 193 tests actuales intactos, fixtures no movidos, cuatro loopback siguen separados.
- **Seguridad rápida:** perfil fast limita velocidad a 6°/s, comprueba pose ≤0,20 s y calcula horizonte con pulso 0,20 + edad/freno conservadores. Medición manual de freno necesaria; si supera 0,25 s, no habilitar.
- **Pendiente deliberada:** no subir a 12°/s. El flag de app activa solo el perfil rápido de este plan; un incremento de SafetyPolicy también requeriría resolver el guard NavigationLimits fijo de GimbalController en otra decisión.
- **Riesgo/decisión de integración:** el protocolo de calibración usa zonas de seguridad temporales no persistidas para que GotoNavigator ejecute los microgiros. Se aborta si la zona actual no ofrece margen o STOP cambia el token; no se crea un camino de movimiento sin lease.
