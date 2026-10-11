# GimbalKit — Plan 2: driver de la Osmo SE (telemetría, pose, dispositivo y Bluetooth)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un `OMDevice: GimbalDevice` que habla con la Osmo Mobile SE: decodifica su telemetría real (orientación y batería), estima la pose en grados, convierte velocidades a unidades del protocolo y manda órdenes SPEED; más un transporte CoreBluetooth y una prueba de humo con hardware.

**Architecture:** `OMDevice` (actor) depende de un protocolo `OMTransport` (escribir bytes, recibir notificaciones), de modo que toda la lógica se prueba con un transporte falso y **tramas reales capturadas**. CoreBluetooth vive en un módulo aparte, `GimbalKitBLE`, para que `GimbalKitDJI` siga siendo puro. El driver declara solo las capacidades verificadas en hardware: `speedControl`, `poseFeedback`, `battery` (sin `absoluteControl` ni `joystickInput`).

**Tech Stack:** Swift 6 (concurrencia estricta), Swift Testing, CoreBluetooth. Sin dependencias externas.

**Spec:** `docs/superpowers/specs/2026-10-11-gimbalkit-v1-design.md` (§2 hechos medidos y §5 driver). Hechos de esta captura: `docs/research/telemetria-om-se.md`. Continúa el Plan 1 (`2026-10-11-plan-1-nucleo-codec-seguridad.md`).

## Global Constraints

- Mismas reglas que el Plan 1 (Swift 6, `actor` para estado compartido, sin dependencias, un commit por tarea en español, `timeout 300 swift test`, una sola compilación a la vez).
- Convención de ángulos (medida): `Pose` en grados; el **yaw** es el giro alrededor del eje Y del cuaternión y el **pitch** es el opuesto del giro alrededor del eje X (descomposición YXZ sobre la rotación relativa a una referencia). Una orden `+` en yaw o pitch aumenta esos ángulos.
- Unidad de velocidad: **10 unidades crudas por °/s** (0,1 °/s por unidad), tope ±1000 unidades.
- Parámetro `time` de las órdenes SPEED = 10 y `sequence` = 1 (los únicos valores verificados con la SE).
- Las órdenes de velocidad se deben espaciar **≥ 0,25 s**: con 0,1 s la Osmo no obedeció. Esa cadencia es responsabilidad del llamador/host, y debe quedar documentada en `OMDevice`.
- `GimbalKitDJI` no importa CoreBluetooth. `GimbalKitBLE` no contiene lógica de protocolo.
- La Task 5 no se puede probar sin hardware: se exige que compile y que la Task 6 (manual) la valide.

## Review Focus

- Tramas de telemetría truncadas, con carga corta, con floats no finitos o cuaternión de norma 0: `decode` devuelve `nil` y nunca revienta.
- Pose en el límite de singularidad (pitch ±90°): `asin` fuera de rango por redondeo no debe producir `NaN`.
- Velocidades no finitas o enormes: la conversión a unidades no debe desbordar `Int16` ni producir órdenes aleatorias (`NaN` → 0).
- `currentPose()` antes de recibir la primera trama de orientación: `nil`, no una pose inventada.
- Órdenes `absolute` al driver: error explícito, nunca ignoradas en silencio.

---

## File Structure

```
Package.swift                         (modificar: dependencia de tests, target GimbalKitBLE y GimbalSmoke)
Sources/GimbalKitDJI/
  Quaternion.swift                    Quaternion y operaciones
  OMTelemetry.swift                   decodificación de 0x04/0x05 y 0x05/0x06
  OMPoseEstimator.swift               cuaternión → Pose relativa a una referencia
  OMUnits.swift                       °/s ↔ unidades crudas
  OMDevice.swift                      OMTransport, OMDevice (GimbalDevice)
Sources/GimbalKitBLE/
  CoreBluetoothOMTransport.swift      transporte CoreBluetooth (macOS/iOS)
Sources/GimbalSmoke/main.swift        prueba de humo con hardware
scripts/run-smoke.sh                  empaqueta GimbalSmoke en una .app con permiso de Bluetooth y la lanza
Tests/GimbalKitDJITests/
  RealFrames.swift  TelemetryTests.swift  PoseEstimatorTests.swift  UnitsTests.swift  OMDeviceTests.swift
```

Vectores reales (de `docs/research/capturas/`), usados en varias tareas. Pegar tal cual en `RealFrames.swift`:

```swift
import GimbalKitDJI

func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let s = hex.index(hex.startIndex, offsetBy: $0)
        return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)!
    }
}

func frame(_ hex: String) -> DUMLFrame {
    var parser = DUMLParser()
    return parser.feed(bytes(hex))[0]
}

enum Real {
    // Giro de yaw con `yaw = 100` (2 s): de A a B ≈ +21,89° de yaw, +0,21° de pitch, +0,29° de roll.
    static let yawA = "553e044b04026e7c00040501f9fcff000084000300200132c503002c1800000c005403e36ab83eb4debbbea1fe193f98821cbf000000000100000000f6bc"
    static let yawB = "553e044b0402dfc300040501f9fcffd90084002cff2001a2dc0300ba2000000c0054032280f03e92f3f2be6a5c053f192408bf0000000000000000006780"
    // Giro de pitch con `pitch = 100` (2 s): de A a B ≈ −0,01° de yaw, +21,93° de pitch, −0,01° de roll.
    static let pitchA = "553e044b04025a1b000405fd060000020084000a002001b3181100ae440000f7ff4b033707353f83c034bfd535063d35f899bc0000000001000000003323"
    static let pitchB = "553e044b0402cb6200040522060000130084006a00200123301100ad44000003ffe802c09f323f29df2fbfc3802a3e668aed3d0000000001000000002bea"
    // Batería: carga[0] = 0x19 (25 %), último byte 0 (sin cargar).
    static let battery = "5535046827029e00400506190a1c00000000000000000000000000000e000e000000000000000000000000910b000000000000734a"
    // Telemetría constante (0x04/0x57): no se interpreta.
    static let constant = "5513040327021603400457000000000100e451"
}
```

---

### Task 1: Quaternion y decodificación de telemetría

**Files:**
- Create: `Sources/GimbalKitDJI/Quaternion.swift`, `Sources/GimbalKitDJI/OMTelemetry.swift`
- Modify: `Package.swift` (el test target `GimbalKitDJITests` pasa a depender de `GimbalKit` además de `GimbalKitDJI`)
- Test: `Tests/GimbalKitDJITests/RealFrames.swift`, `Tests/GimbalKitDJITests/TelemetryTests.swift`

**Interfaces:**
- Consumes: `DUMLFrame` (Plan 1).
- Produces: `public struct Quaternion: Sendable, Equatable { x, y, z, w: Double; init(x:y:z:w:); var normalized: Quaternion?; var conjugate: Quaternion; static func * (lhs: Quaternion, rhs: Quaternion) -> Quaternion }` y `public enum OMTelemetry: Sendable, Equatable { case attitude(Quaternion); case battery(percent: Int, charging: Bool); static func decode(_ frame: DUMLFrame) -> OMTelemetry? }`.

- [ ] **Step 1: Escribir la prueba que falla**

`RealFrames.swift` como arriba. `Tests/GimbalKitDJITests/TelemetryTests.swift`:
```swift
import Testing
@testable import GimbalKitDJI

@Test func decodesAttitudeQuaternionFromRealFrame() throws {
    let telemetry = try #require(OMTelemetry.decode(frame(Real.yawA)))
    guard case let .attitude(q) = telemetry else { Issue.record("no es attitude"); return }
    #expect(abs(q.x - (0.360190)) < 0.0001)
    #expect(abs(q.y - (-0.366933)) < 0.0001)
    #expect(abs(q.z - (0.601542)) < 0.0001)
    #expect(abs(q.w - (-0.611368)) < 0.0001)
    let norm = (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w).squareRoot()
    #expect(abs(norm - 1) < 1e-6)
}

@Test func decodesBatteryFromRealFrame() {
    #expect(OMTelemetry.decode(frame(Real.battery)) == .battery(percent: 25, charging: false))
}

@Test func ignoresUnknownMessages() {
    #expect(OMTelemetry.decode(frame(Real.constant)) == nil)
}

@Test func truncatedOrInvalidPayloadsDecodeToNil() {
    var f = frame(Real.yawA)
    f.payload = Array(f.payload.prefix(39))
    #expect(OMTelemetry.decode(f) == nil)
    f.payload = [UInt8](repeating: 0, count: 49)            // cuaternión de norma 0
    #expect(OMTelemetry.decode(f) == nil)
    f.payload = [UInt8](repeating: 0xFF, count: 49)         // floats NaN
    #expect(OMTelemetry.decode(f) == nil)
    var b = frame(Real.battery)
    b.payload = []
    #expect(OMTelemetry.decode(b) == nil)
    b.payload = [250, 0]                                    // porcentaje imposible
    #expect(OMTelemetry.decode(b) == nil)
}

@Test func quaternionAlgebra() throws {
    let s = (0.5).squareRoot()
    let q = try #require(Quaternion(x: 0, y: s, z: 0, w: s).normalized)
    let identity = q * q.conjugate
    #expect(abs(identity.w - 1) < 1e-9 && abs(identity.x) < 1e-9 && abs(identity.y) < 1e-9 && abs(identity.z) < 1e-9)
    #expect(Quaternion(x: 0, y: 0, z: 0, w: 0).normalized == nil)
    #expect(Quaternion(x: .nan, y: 0, z: 0, w: 1).normalized == nil)
}
```
Modificar `Package.swift`: `.testTarget(name: "GimbalKitDJITests", dependencies: ["GimbalKitDJI", "GimbalKit"])`.

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `cd /Users/jesusvictorio/Documents/repos/Personales/GimbalKit && CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift test --disable-sandbox --scratch-path .build --filter TelemetryTests 2>&1 | tail -10`
Expected: error `cannot find 'OMTelemetry' in scope`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKitDJI/Quaternion.swift`:
```swift
public struct Quaternion: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    /// Normalizado, o nil si no es finito o su norma no es creíble (fuera de 0,9...1,1 antes de normalizar).
    public var normalized: Quaternion? {
        let n = (x * x + y * y + z * z + w * w).squareRoot()
        guard n.isFinite, n > 0.9, n < 1.1 else { return nil }
        return Quaternion(x: x / n, y: y / n, z: z / n, w: w / n)
    }

    public var conjugate: Quaternion { Quaternion(x: -x, y: -y, z: -z, w: w) }

    public static func * (a: Quaternion, b: Quaternion) -> Quaternion {
        Quaternion(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }
}
```
`Sources/GimbalKitDJI/OMTelemetry.swift`:
```swift
/// Mensajes de telemetría de la serie OM que sabemos interpretar (medidos en hardware, ver docs/research).
public enum OMTelemetry: Sendable, Equatable {
    case attitude(Quaternion)
    case battery(percent: Int, charging: Bool)

    public static func decode(_ frame: DUMLFrame) -> OMTelemetry? {
        switch (frame.commandSet, frame.command) {
        case (0x04, 0x05):
            // Cuaternión (x, y, z, w) como 4 × Float32 LE en carga[24..<40].
            guard frame.payload.count >= 40 else { return nil }
            let f = (0..<4).map { i -> Double in
                let o = 24 + i * 4
                let raw = UInt32(frame.payload[o]) | UInt32(frame.payload[o + 1]) << 8
                    | UInt32(frame.payload[o + 2]) << 16 | UInt32(frame.payload[o + 3]) << 24
                return Double(Float(bitPattern: raw))
            }
            guard let q = Quaternion(x: f[0], y: f[1], z: f[2], w: f[3]).normalized else { return nil }
            return .attitude(q)
        case (0x05, 0x06):
            guard let first = frame.payload.first, first <= 100, let last = frame.payload.last else { return nil }
            return .battery(percent: Int(first), charging: last == 1)
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `... swift test ... --filter TelemetryTests 2>&1 | tail -8`
Expected: `Test run with 5 tests passed`.

- [ ] **Step 5: Commit** (lo hace Claude si el sandbox no deja): `feat: cuaternión y decodificación de telemetría de la Osmo SE`

---

### Task 2: Estimador de pose

**Files:**
- Create: `Sources/GimbalKitDJI/OMPoseEstimator.swift`
- Test: `Tests/GimbalKitDJITests/PoseEstimatorTests.swift`

**Interfaces:**
- Consumes: `Quaternion`, `OMTelemetry` (Task 1); `Pose` (`GimbalKit`).
- Produces: `public struct OMPoseEstimator: Sendable { init(); private(set) var pose: Pose?; mutating func update(_ q: Quaternion) -> Pose; mutating func zero() }`. La primera orientación tras `init()`/`zero()` es la referencia (pose 0,0,0).

- [ ] **Step 1: Escribir la prueba que falla**

`Tests/GimbalKitDJITests/PoseEstimatorTests.swift`:
```swift
import Testing
import GimbalKit
@testable import GimbalKitDJI

private func attitude(_ hex: String) -> Quaternion {
    guard case let .attitude(q)? = OMTelemetry.decode(frame(hex)) else { fatalError("trama sin orientación") }
    return q
}

@Test func firstOrientationBecomesTheZeroReference() {
    var estimator = OMPoseEstimator()
    #expect(estimator.pose == nil)
    let pose = estimator.update(attitude(Real.yawA))
    #expect(abs(pose.yaw) < 1e-9 && abs(pose.pitch) < 1e-9 && abs(pose.roll) < 1e-9)
}

@Test func realYawMoveMatchesMeasuredAngles() {
    var estimator = OMPoseEstimator()
    _ = estimator.update(attitude(Real.yawA))
    let pose = estimator.update(attitude(Real.yawB))
    #expect(abs(pose.yaw - 21.89) < 0.1)
    #expect(abs(pose.pitch - 0.21) < 0.1)
    #expect(abs(pose.roll - 0.29) < 0.1)
    #expect(estimator.pose == pose)
}

@Test func realPitchMoveMatchesMeasuredAnglesWithFlippedSign() {
    var estimator = OMPoseEstimator()
    _ = estimator.update(attitude(Real.pitchA))
    let pose = estimator.update(attitude(Real.pitchB))
    #expect(abs(pose.yaw - (-0.01)) < 0.1)
    #expect(abs(pose.pitch - 21.93) < 0.1)
    #expect(abs(pose.roll - (-0.01)) < 0.1)
}

@Test func zeroTakesTheNextOrientationAsNewReference() {
    var estimator = OMPoseEstimator()
    _ = estimator.update(attitude(Real.yawA))
    _ = estimator.update(attitude(Real.yawB))
    estimator.zero()
    #expect(estimator.pose == nil)
    let pose = estimator.update(attitude(Real.yawB))
    #expect(abs(pose.yaw) < 1e-9)
}

@Test func gimbalLockNeverProducesNaN() throws {
    // Rotación de 90° alrededor de X respecto a la identidad: pitch en el límite de asin.
    let s = (0.5).squareRoot()
    var estimator = OMPoseEstimator()
    _ = estimator.update(Quaternion(x: 0, y: 0, z: 0, w: 1))
    let pose = estimator.update(Quaternion(x: s, y: 0, z: 0, w: s))
    #expect(pose.yaw.isFinite && pose.pitch.isFinite && pose.roll.isFinite)
    #expect(abs(abs(pose.pitch) - 90) < 0.5)
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `... swift test ... --filter PoseEstimatorTests 2>&1 | tail -10`
Expected: error `cannot find 'OMPoseEstimator' in scope`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKitDJI/OMPoseEstimator.swift`:
```swift
import Foundation
import GimbalKit

/// Convierte el cuaternión de la Osmo en una `Pose` en grados relativa a una referencia (la primera orientación recibida).
/// Descomposición YXZ de la rotación relativa: Y = yaw, X = pitch (con el signo invertido, medido en hardware), Z = roll.
public struct OMPoseEstimator: Sendable {
    private var reference: Quaternion?
    public private(set) var pose: Pose?

    public init() {}

    public mutating func zero() {
        reference = nil
        pose = nil
    }

    @discardableResult
    public mutating func update(_ q: Quaternion) -> Pose {
        let ref = reference ?? q
        reference = ref
        let d = q * ref.conjugate
        let r02 = 2 * (d.x * d.z + d.y * d.w)
        let r12 = 2 * (d.y * d.z - d.x * d.w)
        let r22 = 1 - 2 * (d.x * d.x + d.y * d.y)
        let r10 = 2 * (d.x * d.y + d.z * d.w)
        let r11 = 1 - 2 * (d.x * d.x + d.z * d.z)
        let yaw = atan2(r02, r22)
        let thetaX = asin(max(-1, min(1, -r12)))
        let roll = atan2(r10, r11)
        let result = Pose(
            yaw: yaw * 180 / .pi,
            pitch: -thetaX * 180 / .pi,
            roll: roll * 180 / .pi
        )
        pose = result
        return result
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `... swift test ... --filter PoseEstimatorTests 2>&1 | tail -8`
Expected: `Test run with 5 tests passed`. Si un ángulo real no cuadra, **no tocar las expectativas**: revisar la fórmula contra `docs/research/telemetria-om-se.md`.

- [ ] **Step 5: Commit:** `feat: estimador de pose de la Osmo SE con datos reales`

---

### Task 3: Conversión de unidades

**Files:**
- Create: `Sources/GimbalKitDJI/OMUnits.swift`
- Test: `Tests/GimbalKitDJITests/UnitsTests.swift`

**Interfaces:**
- Produces: `public enum OMUnits { static let unitsPerDegreePerSecond: Double; static let maxRaw: Int16; static func raw(forDegreesPerSecond: Double) -> Int16; static func degreesPerSecond(forRaw: Int16) -> Double }`.

- [ ] **Step 1: Escribir la prueba que falla**

`Tests/GimbalKitDJITests/UnitsTests.swift`:
```swift
import Testing
@testable import GimbalKitDJI

@Test func convertsDegreesPerSecondToRawUnits() {
    #expect(OMUnits.raw(forDegreesPerSecond: 10) == 100)
    #expect(OMUnits.raw(forDegreesPerSecond: -5.04) == -50)
    #expect(OMUnits.raw(forDegreesPerSecond: 0) == 0)
    #expect(OMUnits.degreesPerSecond(forRaw: 250) == 25)
}

@Test func clampsAndNeutralizesBadValues() {
    #expect(OMUnits.raw(forDegreesPerSecond: 1_000_000) == OMUnits.maxRaw)
    #expect(OMUnits.raw(forDegreesPerSecond: -1_000_000) == -OMUnits.maxRaw)
    #expect(OMUnits.raw(forDegreesPerSecond: .nan) == 0)
    #expect(OMUnits.raw(forDegreesPerSecond: .infinity) == 0)
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `... swift test ... --filter UnitsTests 2>&1 | tail -6` → `cannot find 'OMUnits' in scope`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKitDJI/OMUnits.swift`:
```swift
/// 10 unidades crudas por °/s (≈ 0,1 °/s por unidad; medido en la SE entre 100 y 400 unidades).
public enum OMUnits {
    public static let unitsPerDegreePerSecond = 10.0
    public static let maxRaw: Int16 = 1000

    public static func raw(forDegreesPerSecond value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let scaled = (value * unitsPerDegreePerSecond).rounded()
        return Int16(max(-Double(maxRaw), min(Double(maxRaw), scaled)))
    }

    public static func degreesPerSecond(forRaw raw: Int16) -> Double {
        Double(raw) / unitsPerDegreePerSecond
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa** → `Test run with 2 tests passed`.

- [ ] **Step 5: Commit:** `feat: conversión de unidades de velocidad de la serie OM`

---

### Task 4: OMDevice con transporte falso

**Files:**
- Create: `Sources/GimbalKitDJI/OMDevice.swift`
- Test: `Tests/GimbalKitDJITests/OMDeviceTests.swift`

**Interfaces:**
- Consumes: `DUMLParser`, `OMRotate`, `OMTelemetry`, `OMPoseEstimator`, `OMUnits` (Plan 1 + tareas 1–3); `GimbalDevice`, `MoveCommand`, `Capabilities`, `Pose` (`GimbalKit`).
- Produces: `public protocol OMTransport: Sendable { func write(_ bytes: [UInt8]) async throws; var notifications: AsyncStream<[UInt8]> { get } }`, `public enum OMDeviceError: Error, Equatable { case unsupported(String) }`, `public actor OMDevice: GimbalDevice { init(transport: any OMTransport); func start(); func shutdown(); func zeroPose(); var battery: (percent: Int, charging: Bool)? { get } }`. Capacidades: `[.speedControl, .poseFeedback, .battery]`.

- [ ] **Step 1: Escribir la prueba que falla**

`Tests/GimbalKitDJITests/OMDeviceTests.swift`:
```swift
import Testing
import GimbalKit
@testable import GimbalKitDJI

actor FakeTransport: OMTransport {
    nonisolated let notifications: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private(set) var written: [[UInt8]] = []

    init() {
        (notifications, continuation) = AsyncStream.makeStream(of: [UInt8].self)
    }

    func write(_ bytes: [UInt8]) async throws { written.append(bytes) }

    nonisolated func push(_ bytes: [UInt8]) { continuation.yield(bytes) }
}

private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Test func declaresOnlyVerifiedCapabilities() {
    let device = OMDevice(transport: FakeTransport())
    #expect(device.capabilities == [.speedControl, .poseFeedback, .battery])
}

@Test func speedCommandBecomesRawSpeedFrame() async throws {
    let transport = FakeTransport()
    let device = OMDevice(transport: transport)
    try await device.send(.speed(yaw: 60, pitch: 0, roll: 0))
    #expect(await transport.written == [OMRotate(yaw: 600, pitch: 0, roll: 0, time: 10, mode: .speed).frame().encoded()])
    try await device.send(.speed(yaw: -10, pitch: 5, roll: 99))      // el roll no está soportado: se manda 0
    let expected = OMRotate(yaw: -100, pitch: 50, roll: 0, time: 10, mode: .speed).frame().encoded()
    #expect(await transport.written.last == expected)
}

@Test func stopSendsZeroSpeedFrame() async throws {
    let transport = FakeTransport()
    let device = OMDevice(transport: transport)
    try await device.send(.stop)
    #expect(await transport.written == [bytes("551504a90204010000040c000000000000800a2c40")])
}

@Test func absoluteCommandsAreRejectedExplicitly() async {
    let device = OMDevice(transport: FakeTransport())
    await #expect(throws: OMDeviceError.unsupported("absolute")) {
        try await device.send(.absolute(Pose(yaw: 10, pitch: 0), seconds: 1))
    }
}

@Test func poseIsNilUntilFirstAttitudeThenTracksRealFrames() async throws {
    let transport = FakeTransport()
    let device = OMDevice(transport: transport)
    await device.start()
    #expect(await device.currentPose() == nil)
    for hex in [Real.yawA, Real.yawB] {
        let b = bytes(hex)
        transport.push(Array(b[0..<20]))          // la trama llega partida en dos notificaciones
        transport.push(Array(b[20...]))
    }
    let tracked = await waitUntil { await device.currentPose().map { abs($0.yaw - 21.89) < 0.1 } ?? false }
    #expect(tracked)
    await device.zeroPose()
    #expect(await device.currentPose() == nil)
    await device.shutdown()
}

@Test func batteryIsReadFromTelemetry() async {
    let transport = FakeTransport()
    let device = OMDevice(transport: transport)
    await device.start()
    transport.push(bytes(Real.battery))
    let got = await waitUntil { await device.battery?.percent == 25 }
    #expect(got)
    #expect(await device.battery?.charging == false)
    await device.shutdown()
}

@Test func garbageNotificationsNeverBreakTheDevice() async throws {
    let transport = FakeTransport()
    let device = OMDevice(transport: transport)
    await device.start()
    transport.push([0x55, 0xFF, 0x00, 0x13, 0x37])
    transport.push(bytes(Real.constant))
    transport.push(bytes(Real.yawA))
    let ok = await waitUntil { await device.currentPose() != nil }
    #expect(ok)
    await device.shutdown()
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `... swift test ... --filter OMDeviceTests 2>&1 | tail -10` → `cannot find 'OMDevice' in scope`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKitDJI/OMDevice.swift`:
```swift
import GimbalKit

public protocol OMTransport: Sendable {
    func write(_ bytes: [UInt8]) async throws
    var notifications: AsyncStream<[UInt8]> { get }
}

public enum OMDeviceError: Error, Equatable {
    case unsupported(String)
}

/// Osmo Mobile SE como `GimbalDevice`. Solo declara lo verificado en hardware.
///
/// Las órdenes de velocidad deben espaciarse ≥ 0,25 s (con 0,1 s la Osmo no obedeció) y la pose llega a ~1,5 Hz:
/// quien llame (el host) es responsable de la cadencia y de tratar la pose como retardada.
public actor OMDevice: GimbalDevice {
    public nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback, .battery]
    public private(set) var battery: (percent: Int, charging: Bool)?

    private let transport: any OMTransport
    private var parser = DUMLParser()
    private var estimator = OMPoseEstimator()
    private var listener: Task<Void, Never>?

    public init(transport: any OMTransport) {
        self.transport = transport
    }

    public func start() {
        guard listener == nil else { return }
        let stream = transport.notifications
        listener = Task { [weak self] in
            for await chunk in stream {
                await self?.ingest(chunk)
            }
        }
    }

    public func shutdown() {
        listener?.cancel()
        listener = nil
    }

    public func zeroPose() {
        estimator.zero()
    }

    public func send(_ command: MoveCommand) async throws {
        switch command {
        case let .speed(yaw, pitch, _):
            try await write(yaw: OMUnits.raw(forDegreesPerSecond: yaw), pitch: OMUnits.raw(forDegreesPerSecond: pitch))
        case .stop:
            try await write(yaw: 0, pitch: 0)
        case .absolute:
            throw OMDeviceError.unsupported("absolute")
        }
    }

    public func currentPose() -> Pose? {
        estimator.pose
    }

    private func write(yaw: Int16, pitch: Int16) async throws {
        let rotate = OMRotate(yaw: yaw, pitch: pitch, roll: 0, time: 10, mode: .speed)
        try await transport.write(rotate.frame().encoded())
    }

    private func ingest(_ chunk: [UInt8]) {
        for frame in parser.feed(chunk) {
            switch OMTelemetry.decode(frame) {
            case let .attitude(q)?: estimator.update(q)
            case let .battery(percent, charging)?: battery = (percent, charging)
            case nil: break
            }
        }
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `... swift test ... --filter OMDeviceTests 2>&1 | tail -10` → `Test run with 7 tests passed`. Después la suite completa: `timeout 300 swift test ...` → todo verde (Plan 1: 40 pruebas + 19 nuevas = 59).

- [ ] **Step 5: Commit:** `feat: OMDevice sobre un transporte abstracto, probado con tramas reales`

---

### Task 5: Transporte CoreBluetooth y prueba de humo

**Files:**
- Modify: `Package.swift` (añadir `GimbalKitBLE` y el ejecutable `GimbalSmoke`)
- Create: `Sources/GimbalKitBLE/CoreBluetoothOMTransport.swift`, `Sources/GimbalSmoke/main.swift`, `scripts/run-smoke.sh`

**Interfaces:**
- Consumes: `OMTransport`, `OMDevice`, `OMRotate` (Task 4).
- Produces: `public final class CoreBluetoothOMTransport: NSObject, OMTransport, @unchecked Sendable { init(); func connect(timeout: TimeInterval) async throws; func disconnect(); var onDisconnect: (@Sendable () -> Void)? }`, `public enum BLEError: Error { case bluetoothUnavailable, notFound, timedOut, discoveryFailed }`.

Esta tarea **no tiene prueba automática** (necesita hardware y permiso de Bluetooth). El criterio es que compile sin avisos de concurrencia y que la Task 6 la valide.

- [ ] **Step 1: Package.swift**

Añadir a `products` `.library(name: "GimbalKitBLE", targets: ["GimbalKitBLE"])`; a `targets`:
```swift
.target(name: "GimbalKitBLE", dependencies: ["GimbalKitDJI"]),
.executableTarget(name: "GimbalSmoke", dependencies: ["GimbalKitBLE", "GimbalKitDJI", "GimbalKit"]),
```

- [ ] **Step 2: El transporte**

`Sources/GimbalKitBLE/CoreBluetoothOMTransport.swift`:
```swift
import CoreBluetooth
import Foundation
import GimbalKitDJI

public enum BLEError: Error, Equatable {
    case bluetoothUnavailable, notFound, timedOut, discoveryFailed
}

/// Transporte CoreBluetooth para la serie OM: servicio FFF0, notificaciones en FFF4, escritura sin respuesta en FFF5.
/// Primero recupera una Osmo ya conectada al sistema (queda conectada como HID y no se anuncia); si no, escanea por servicio.
/// Todo el estado mutable se toca solo en `queue` (también el delegado).
public final class CoreBluetoothOMTransport: NSObject, OMTransport, @unchecked Sendable {
    public let notifications: AsyncStream<[UInt8]>
    public var onDisconnect: (@Sendable () -> Void)?

    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let queue = DispatchQueue(label: "gimbalkit.ble")
    private static let service = CBUUID(string: "FFF0")
    private static let notifyUUID = CBUUID(string: "FFF4")
    private static let writeUUID = CBUUID(string: "FFF5")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var connection: CheckedContinuation<Void, Error>?

    public override init() {
        (notifications, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    public func connect(timeout: TimeInterval = 15) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connection = cont
                self.queue.asyncAfter(deadline: .now() + timeout) { self.finishConnection(.failure(BLEError.timedOut)) }
                self.beginIfPoweredOn()
            }
        }
    }

    public func disconnect() {
        queue.async {
            if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let peripheral = self.peripheral, let characteristic = self.writeCharacteristic else {
                    cont.resume(throwing: BLEError.notFound)
                    return
                }
                let size = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
                var offset = 0
                while offset < bytes.count {
                    let end = min(offset + size, bytes.count)
                    peripheral.writeValue(Data(bytes[offset..<end]), for: characteristic, type: .withoutResponse)
                    offset = end
                }
                cont.resume()
            }
        }
    }

    // MARK: Conexión (siempre en `queue`)

    private func beginIfPoweredOn() {
        switch central.state {
        case .poweredOn:
            if let found = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
                attach(found)
            } else {
                central.scanForPeripherals(withServices: [Self.service])
            }
        case .unknown, .resetting:
            break                                   // centralManagerDidUpdateState reintentará
        default:
            finishConnection(.failure(BLEError.bluetoothUnavailable))
        }
    }

    private func attach(_ found: CBPeripheral) {
        central.stopScan()
        peripheral = found
        found.delegate = self
        if found.state == .connected {
            found.discoverServices([Self.service])
        } else {
            central.connect(found)
        }
    }

    private func finishConnection(_ result: Result<Void, Error>) {
        guard let cont = connection else { return }
        connection = nil
        cont.resume(with: result)
    }
}

extension CoreBluetoothOMTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if connection != nil { beginIfPoweredOn() }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        attach(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishConnection(.failure(error ?? BLEError.notFound))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        notifyCharacteristic = nil
        writeCharacteristic = nil
        onDisconnect?()
    }
}

extension CoreBluetoothOMTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            finishConnection(.failure(BLEError.discoveryFailed))
            return
        }
        peripheral.discoverCharacteristics([Self.notifyUUID, Self.writeUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        notifyCharacteristic = service.characteristics?.first { $0.uuid == Self.notifyUUID }
        writeCharacteristic = service.characteristics?.first { $0.uuid == Self.writeUUID }
        guard error == nil, let notify = notifyCharacteristic, writeCharacteristic != nil else {
            finishConnection(.failure(BLEError.discoveryFailed))
            return
        }
        peripheral.setNotifyValue(true, for: notify)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        finishConnection(error == nil ? .success(()) : .failure(error!))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.notifyUUID, let data = characteristic.value else { return }
        continuation.yield([UInt8](data))
    }
}
```
Si el compilador exige otra forma para satisfacer la concurrencia estricta (p. ej. `nonisolated(unsafe)` en el estado mutable), aplicar el cambio mínimo y anotar el motivo.

- [ ] **Step 3: Prueba de humo**

`Sources/GimbalSmoke/main.swift`:
```swift
import Foundation
import GimbalKit
import GimbalKitBLE
import GimbalKitDJI

// Uso: GimbalSmoke [--mover]    (salida por stdout; sin --mover no manda ninguna orden de movimiento)
let move = CommandLine.arguments.contains("--mover")
let transport = CoreBluetoothOMTransport()
let device = OMDevice(transport: transport)

do {
    try await transport.connect(timeout: 15)
    print("CONECTADA")
    await device.start()
    try await Task.sleep(for: .seconds(4))
    print("POSE_INICIAL \(String(describing: await device.currentPose()))")
    print("BATERIA \(String(describing: await device.battery))")
    if move {
        for yaw in [10.0, -10.0] {                      // 10 °/s durante 2 s y de vuelta
            let end = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < end {
                try await device.send(.speed(yaw: yaw, pitch: 0, roll: 0))
                try await Task.sleep(for: .milliseconds(300))
            }
            try await device.send(.stop)
            try await Task.sleep(for: .seconds(2))
            print("POSE tras \(yaw) °/s: \(String(describing: await device.currentPose()))")
        }
    }
    try await device.send(.stop)
    await device.shutdown()
    transport.disconnect()
    print("FIN_OK")
} catch {
    try? await device.send(.stop)
    print("ERROR \(error)")
}
```
`scripts/run-smoke.sh`:
```bash
#!/bin/zsh
# Empaqueta GimbalSmoke en una .app con permiso de Bluetooth (un binario suelto lanzado desde el terminal muere con SIGABRT).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox -c release --product GimbalSmoke
APP=".build/GimbalSmoke.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp ".build/release/GimbalSmoke" "$APP/Contents/MacOS/GimbalSmokeBin"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gimbalkit.smoke</string>
<key>CFBundleName</key><string>GimbalSmoke</string>
<key>CFBundleExecutable</key><string>run</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Probar la conexión con el estabilizador.</string>
</dict></plist>
EOF
OUT="${SMOKE_OUT:-/tmp/gimbalkit-smoke.txt}"
printf '#!/bin/zsh\nexec "%s/Contents/MacOS/GimbalSmokeBin" %s > "%s" 2>&1\n' "$PWD/$APP" "${*:-}" "$OUT" > "$APP/Contents/MacOS/run"
chmod +x "$APP/Contents/MacOS/run"
codesign -s - --force --deep "$APP" >/dev/null
rm -f "$OUT"; open -W "$APP"; cat "$OUT"
```
`chmod +x scripts/run-smoke.sh`.

- [ ] **Step 4: Compilar (sin lanzar nada con hardware)**

Run: `CLANG_MODULE_CACHE_PATH=$PWD/.build/modcache timeout 300 swift build --disable-sandbox --scratch-path .build 2>&1 | tail -15`
Expected: `Build complete!` sin avisos de concurrencia. Después `swift test` completo sigue verde. **No ejecutar `run-smoke.sh`**: lo hace Claude con la Osmo delante (Task 6).

- [ ] **Step 5: Commit:** `feat: transporte CoreBluetooth y prueba de humo con la Osmo SE`

---

### Task 6 (manual, la hace Claude con Jesús y la Osmo)

- [ ] `scripts/run-smoke.sh` (sin `--mover`): esperar `CONECTADA`, una `POSE_INICIAL` no nula y `BATERIA`.
- [ ] `scripts/run-smoke.sh --mover`: la Osmo gira ~20° a la derecha y vuelve; las `POSE` impresas deben acercarse a +20° y ~0°. Registrar cifras reales en `docs/research/telemetria-om-se.md`.
- [ ] Actualizar `docs/superpowers/plans/ESTADO.md` (M2 hecho o lo que falte) y commit.

---

## Autorrevisión

- **Cobertura:** §5 de la spec (códec ya hecho; `OMConnection` → Task 5 con descubrimiento «recuperar conectado → escanear»; reconoce solo órdenes verificadas → capacidades limitadas). §2 hechos medidos → vectores reales en las pruebas. M2 queda cubierto salvo el joystick/botones (HID), que se anota como trabajo del Plan 3.
- **Marcadores:** ninguno; el código está completo. La Task 5 declara explícitamente su límite (sin prueba automática).
- **Consistencia de tipos:** `Quaternion`, `OMTelemetry`, `OMPoseEstimator.update` (discardable), `OMUnits.raw(forDegreesPerSecond:)`, `OMTransport.write/notifications`, `OMDevice.start/shutdown/zeroPose/battery` coinciden entre tareas; `bytes(_:)` y `frame(_:)` viven en `RealFrames.swift` y los reutilizan todas las pruebas.
- **Review Focus:** truncadas/NaN/norma 0 → Task 1; singularidad → Task 2; velocidades enormes y NaN → Task 3; pose nil antes de telemetría y absolute explícito → Task 4.
- **Pendiente deliberado (Plan 3):** controlador «ir a zona» en bucle cerrado sobre pose retardada, joystick/botones por HID, host macOS + MCP, app iOS + Atajos.
