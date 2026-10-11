# GimbalKit — Plan 1: núcleo, simulador, códec DUML y seguridad

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un paquete Swift que compila y pasa sus pruebas sin hardware: tipos del núcleo, simulador, códec DUML (con vectores de oro) y el controlador con política de seguridad, turno de control, leases, deadman y registro.

**Architecture:** `GimbalKit` es el núcleo y no sabe nada de Bluetooth; `GimbalKitSim` y `GimbalKitDJI` dependen de él. El `GimbalController` (actor) es el único camino hacia un `GimbalDevice` y aplica todas las reglas de seguridad; las fachadas futuras (Atajos, MCP) solo hablan con él. El reloj se inyecta (`now`) y el deadman se evalúa en `tick()`, para que todo sea determinista en pruebas.

**Tech Stack:** Swift 6 (concurrencia estricta), SwiftPM, Swift Testing (`import Testing`), sin dependencias externas. macOS 14+ / iOS 17+.

**Spec:** `docs/superpowers/specs/2026-10-11-gimbalkit-v1-design.md` (secciones 4, 5 y 8; hitos M0, M1, M3).

## Global Constraints

- Swift tools 6.0, modo de lenguaje Swift 6, plataformas `.macOS(.v14)`, `.iOS(.v17)`.
- Cero dependencias de terceros. Licencia MIT; `NOTICE` cita `alkersan/om-research` (MIT).
- El nombre del paquete y de los tipos NO contiene «Osmo» ni «DJI» salvo el módulo `GimbalKitDJI` (nombre técnico del driver) y el tipo `OMRotate` (serie «OM»).
- Todo estado compartido va en `actor`; los tipos de valor son `Sendable`.
- Una orden fuera de política se **rechaza con un `SafetyViolation` tipado**, nunca se recorta en silencio.
- Una sola compilación/suite Swift a la vez en el Mac; ejecutar siempre con `timeout 300 swift test ...`.
- Un commit por tarea, mensajes en español con prefijo (`feat:`, `test:`, `docs:`).
- Ninguna tarea toca Bluetooth ni hardware: eso es el Plan 2.

## Review Focus

- Valores no finitos (`NaN`, `±inf`) en velocidades o poses: `abs(NaN) > max` es falso y se colaría; debe rechazarse (`invalidValue`).
- Duración de lease cero, negativa o no finita: debe rechazarse (`invalidDuration`), no crear un lease ya caducado.
- Dos agentes pidiendo lease a la vez: exactamente uno lo obtiene, el otro recibe `busy`.
- Parser DUML alimentado con basura, tramas partidas en trozos, longitudes absurdas o CRC corruptos: nunca se cuelga, nunca devuelve una trama inválida.
- `tick()` sin movimiento activo no debe enviar paradas repetidas (spam al dispositivo); la zona vacía (`zones: []`) debe rechazar cualquier lease con `unknownZone`.

---

## File Structure

```
Package.swift
LICENSE  NOTICE  README.md  .gitignore
Sources/GimbalKit/
  Types.swift            Pose, Capabilities, MoveCommand, ControlSource, Zone, GimbalDevice
  SafetyPolicy.swift     SafetyPolicy, SafetyViolation
  Audit.swift            AuditEntry, AuditLog
  Lease.swift            Lease
  GimbalController.swift actor: leases, validación, deadman, parada
Sources/GimbalKitSim/
  SimGimbal.swift        actor GimbalDevice simulado
  ManualClock.swift      reloj manual para pruebas
Sources/GimbalKitDJI/
  DUMLCRC.swift          CRC8 y CRC16 de DUML
  DUMLFrame.swift        DUMLFrame (codificar) y DUMLParser (decodificar)
  OMRotate.swift         orden de giro de la serie OM → DUMLFrame
Tests/GimbalKitTests/    TypesTests, SimGimbalTests, SafetyTests, ControllerTests, DeadmanTests, Fixtures
Tests/GimbalKitDJITests/ DUMLCodecTests
```

---

### Task 1: Paquete y tipos del núcleo

**Files:**
- Create: `Package.swift`, `.gitignore`, `LICENSE`, `NOTICE`, `README.md`
- Create: `Sources/GimbalKit/Types.swift`
- Create: `Sources/GimbalKitSim/SimGimbal.swift` (marcador mínimo para que el target compile)
- Create: `Sources/GimbalKitDJI/DUMLCRC.swift` (marcador mínimo para que el target compile)
- Test: `Tests/GimbalKitTests/TypesTests.swift`, `Tests/GimbalKitDJITests/Placeholder.swift`

**Interfaces:**
- Produces: `Pose`, `Capabilities`, `MoveCommand`, `ControlSource` (con `isPrivileged`), `Zone` (con `contains(_:)`), `protocol GimbalDevice: Sendable { var capabilities: Capabilities { get }; func send(_ command: MoveCommand) async throws; func currentPose() async -> Pose? }`.

- [ ] **Step 1: Crear el esqueleto del paquete**

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
    ],
    targets: [
        .target(name: "GimbalKit"),
        .target(name: "GimbalKitSim", dependencies: ["GimbalKit"]),
        .target(name: "GimbalKitDJI", dependencies: ["GimbalKit"]),
        .testTarget(name: "GimbalKitTests", dependencies: ["GimbalKit", "GimbalKitSim"]),
        .testTarget(name: "GimbalKitDJITests", dependencies: ["GimbalKitDJI"]),
    ]
)
```
`.gitignore`: líneas `.build/`, `.swiftpm/`, `*.xcodeproj/xcuserdata/`, `.DS_Store`.
`LICENSE`: texto MIT estándar, «Copyright (c) 2026 Jesús Victorio».
`NOTICE`:
```
GimbalKit
El códec y la secuencia de órdenes de la serie Osmo Mobile derivan del trabajo de interoperabilidad
https://github.com/alkersan/om-research (licencia MIT).
GimbalKit no está afiliado a DJI. «DJI» y «Osmo» son marcas de sus propietarios.
```
`README.md`: título, una frase de qué es, estado «en desarrollo» y enlace a la spec.
Marcadores: `Sources/GimbalKitSim/SimGimbal.swift` con `import GimbalKit` (una línea), `Sources/GimbalKitDJI/DUMLCRC.swift` con `import GimbalKit` (una línea), `Tests/GimbalKitDJITests/Placeholder.swift` con `import Testing` y `@Test func placeholder() {}`.

- [ ] **Step 2: Escribir la prueba que falla**

`Tests/GimbalKitTests/TypesTests.swift`:
```swift
import Testing
@testable import GimbalKit

@Test func zoneContainsPoseInsideRanges() {
    let zone = Zone(name: "mesa", yaw: -30...30, pitch: -20...20)
    #expect(zone.contains(Pose(yaw: 0, pitch: 0)))
    #expect(zone.contains(Pose(yaw: 30, pitch: -20)))
    #expect(!zone.contains(Pose(yaw: 31, pitch: 0)))
    #expect(!zone.contains(Pose(yaw: 0, pitch: 25)))
}

@Test func zoneRejectsNonFinitePose() {
    let zone = Zone(name: "mesa", yaw: -30...30, pitch: -20...20)
    #expect(!zone.contains(Pose(yaw: .nan, pitch: 0)))
    #expect(!zone.contains(Pose(yaw: 0, pitch: .infinity)))
}

@Test func onlyPhysicalAndAppSourcesArePrivileged() {
    #expect(ControlSource.physical.isPrivileged)
    #expect(ControlSource.app.isPrivileged)
    #expect(!ControlSource.shortcut.isPrivileged)
    #expect(!ControlSource.agent("claude").isPrivileged)
}

@Test func capabilitiesCombine() {
    let caps: Capabilities = [.speedControl, .poseFeedback]
    #expect(caps.contains(.speedControl))
    #expect(!caps.contains(.absoluteControl))
}
```

- [ ] **Step 3: Ejecutar y comprobar que falla**

Run: `cd /Users/jesusvictorio/Documents/repos/Personales/GimbalKit && timeout 300 swift test --filter TypesTests 2>&1 | tail -15`
Expected: error de compilación `cannot find 'Zone' in scope` (o similar).

- [ ] **Step 4: Implementar los tipos**

`Sources/GimbalKit/Types.swift`:
```swift
public struct Pose: Sendable, Equatable, Codable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    public var isFinite: Bool { yaw.isFinite && pitch.isFinite && roll.isFinite }
}

public struct Capabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let speedControl = Capabilities(rawValue: 1 << 0)
    public static let absoluteControl = Capabilities(rawValue: 1 << 1)
    public static let poseFeedback = Capabilities(rawValue: 1 << 2)
    public static let joystickInput = Capabilities(rawValue: 1 << 3)
    public static let battery = Capabilities(rawValue: 1 << 4)
}

/// Velocidades en grados por segundo; poses en grados.
public enum MoveCommand: Sendable, Equatable {
    case speed(yaw: Double, pitch: Double, roll: Double)
    case absolute(Pose, seconds: Double)
    case stop
}

public enum ControlSource: Sendable, Hashable {
    case physical
    case app
    case shortcut
    case agent(String)

    /// Las fuentes del propio usuario (mando físico, app) no necesitan lease y expropian el turno.
    public var isPrivileged: Bool {
        switch self {
        case .physical, .app: true
        case .shortcut, .agent: false
        }
    }
}

public struct Zone: Sendable, Equatable, Codable {
    public var name: String
    public var yaw: ClosedRange<Double>
    public var pitch: ClosedRange<Double>
    public var forbidden: Bool

    public init(name: String, yaw: ClosedRange<Double>, pitch: ClosedRange<Double>, forbidden: Bool = false) {
        self.name = name
        self.yaw = yaw
        self.pitch = pitch
        self.forbidden = forbidden
    }

    public func contains(_ pose: Pose) -> Bool {
        pose.isFinite && yaw.contains(pose.yaw) && pitch.contains(pose.pitch)
    }
}

public protocol GimbalDevice: Sendable {
    var capabilities: Capabilities { get }
    func send(_ command: MoveCommand) async throws
    func currentPose() async -> Pose?
}
```

- [ ] **Step 5: Ejecutar y comprobar que pasa**

Run: `timeout 300 swift test --filter TypesTests 2>&1 | tail -8`
Expected: `Test run with 4 tests passed`.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: paquete GimbalKit y tipos del núcleo"
```

---

### Task 2: Simulador y reloj manual

**Files:**
- Modify: `Sources/GimbalKitSim/SimGimbal.swift` (sustituir el marcador)
- Create: `Sources/GimbalKitSim/ManualClock.swift`
- Test: `Tests/GimbalKitTests/SimGimbalTests.swift`

**Interfaces:**
- Consumes: `GimbalDevice`, `MoveCommand`, `Pose`, `Capabilities` (Task 1).
- Produces: `actor SimGimbal: GimbalDevice` con `init(capabilities: Capabilities = [.speedControl, .absoluteControl, .poseFeedback, .battery], pose: Pose = Pose())`, `commands: [MoveCommand]`, `pose: Pose`, `advance(seconds: Double)`, `failNextSend(with: any Error)`. `final class ManualClock: @unchecked Sendable` con `init(_ start: Date = Date(timeIntervalSince1970: 1_000_000))`, `now() -> Date`, `advance(_ seconds: TimeInterval)`.

- [ ] **Step 1: Escribir la prueba que falla**

`Tests/GimbalKitTests/SimGimbalTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit
import GimbalKitSim

struct Boom: Error, Equatable {}

@Test func simRecordsCommandsAndIntegratesSpeed() async throws {
    let sim = SimGimbal()
    try await sim.send(.speed(yaw: 10, pitch: -5, roll: 0))
    await sim.advance(seconds: 2)
    let pose = await sim.pose
    #expect(pose == Pose(yaw: 20, pitch: -10, roll: 0))
    try await sim.send(.stop)
    await sim.advance(seconds: 5)
    #expect(await sim.pose == pose)
    #expect(await sim.commands.count == 2)
}

@Test func simAbsoluteMovesImmediately() async throws {
    let sim = SimGimbal()
    try await sim.send(.absolute(Pose(yaw: 40, pitch: 10), seconds: 1))
    #expect(await sim.currentPose() == Pose(yaw: 40, pitch: 10))
}

@Test func simWithoutPoseFeedbackHidesPose() async {
    let sim = SimGimbal(capabilities: [.speedControl])
    #expect(await sim.currentPose() == nil)
}

@Test func simCanFailOnce() async throws {
    let sim = SimGimbal()
    await sim.failNextSend(with: Boom())
    await #expect(throws: Boom.self) { try await sim.send(.stop) }
    try await sim.send(.stop)
    #expect(await sim.commands == [.stop])
}

@Test func manualClockAdvances() {
    let clock = ManualClock()
    let t0 = clock.now()
    clock.advance(2.5)
    #expect(clock.now().timeIntervalSince(t0) == 2.5)
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `timeout 300 swift test --filter SimGimbalTests 2>&1 | tail -10`
Expected: error `cannot find 'SimGimbal' in scope`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKitSim/SimGimbal.swift`:
```swift
import GimbalKit

public actor SimGimbal: GimbalDevice {
    public nonisolated let capabilities: Capabilities
    public private(set) var pose: Pose
    public private(set) var commands: [MoveCommand] = []
    private var velocity = Pose()
    private var pendingError: (any Error)?

    public init(
        capabilities: Capabilities = [.speedControl, .absoluteControl, .poseFeedback, .battery],
        pose: Pose = Pose()
    ) {
        self.capabilities = capabilities
        self.pose = pose
    }

    public func send(_ command: MoveCommand) async throws {
        if let error = pendingError {
            pendingError = nil
            throw error
        }
        commands.append(command)
        switch command {
        case let .speed(yaw, pitch, roll):
            velocity = Pose(yaw: yaw, pitch: pitch, roll: roll)
        case let .absolute(target, _):
            pose = target
            velocity = Pose()
        case .stop:
            velocity = Pose()
        }
    }

    public func currentPose() -> Pose? {
        capabilities.contains(.poseFeedback) ? pose : nil
    }

    /// Avanza el tiempo simulado: integra la velocidad actual sobre la pose.
    public func advance(seconds: Double) {
        pose.yaw += velocity.yaw * seconds
        pose.pitch += velocity.pitch * seconds
        pose.roll += velocity.roll * seconds
    }

    public func failNextSend(with error: any Error) {
        pendingError = error
    }
}
```
`Sources/GimbalKitSim/ManualClock.swift`:
```swift
import Foundation

public final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        current = start
    }

    public func now() -> Date { lock.withLock { current } }

    public func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `timeout 300 swift test --filter SimGimbalTests 2>&1 | tail -8`
Expected: `Test run with 5 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: simulador SimGimbal y reloj manual"
```

---

### Task 3: Códec DUML (CRC, trama, parser, orden de giro)

**Files:**
- Modify: `Sources/GimbalKitDJI/DUMLCRC.swift` (sustituir el marcador)
- Create: `Sources/GimbalKitDJI/DUMLFrame.swift`, `Sources/GimbalKitDJI/OMRotate.swift`
- Delete: `Tests/GimbalKitDJITests/Placeholder.swift`
- Test: `Tests/GimbalKitDJITests/DUMLCodecTests.swift`

**Interfaces:**
- Produces: `enum DUMLCRC { static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8; static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 }` (internos); `public struct DUMLFrame: Sendable, Equatable { sender, receiver: UInt8; sequence: UInt16; commandType, commandSet, command: UInt8; payload: [UInt8]; func encoded() -> [UInt8] }`; `public struct DUMLParser { init(); mutating func feed(_ data: [UInt8]) -> [DUMLFrame] }`; `public struct OMRotate: Sendable, Equatable { enum Mode: UInt8 { relative = 0x04, absolute = 0x05, speed = 0x80 }; yaw, pitch, roll: Int16; time: UInt8; mode: Mode; func frame(sequence: UInt16 = 1) -> DUMLFrame }`. Las unidades de `yaw/pitch/roll` son **crudas** (las del protocolo); su conversión a grados es del Plan 2.

Los vectores de oro se generaron con el código de `alkersan/om-research` (`gimbal.py`), y se comprobó que `CRC8([55 15 04]) = 0xa9` y que la CRC16 con semilla `0x3692` sobre toda la trama reproduce la del código de referencia.

- [ ] **Step 1: Escribir la prueba que falla**

`Tests/GimbalKitDJITests/DUMLCodecTests.swift`:
```swift
import Testing
@testable import GimbalKitDJI

private func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let s = hex.index(hex.startIndex, offsetBy: $0)
        return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)!
    }
}

private let golden: [(OMRotate, String)] = [
    (OMRotate(yaw: 600, pitch: 0, roll: 0, time: 10, mode: .speed), "551504a90204010000040c580200000000800aa264"),
    (OMRotate(yaw: -600, pitch: 0, roll: 0, time: 10, mode: .speed), "551504a90204010000040ca8fd00000000800a9ca9"),
    (OMRotate(yaw: 0, pitch: 0, roll: 0, time: 10, mode: .speed), "551504a90204010000040c000000000000800a2c40"),
    (OMRotate(yaw: 900, pitch: -300, roll: 50, time: 20, mode: .relative), "551504a90204010000041484033200d4fe04144e7e"),
    (OMRotate(yaw: 1800, pitch: 0, roll: 0, time: 20, mode: .absolute), "551504a90204010000041408070000000005145d21"),
]

@Test func rotateFramesMatchReferenceVectors() {
    for (rotate, hex) in golden {
        #expect(rotate.frame().encoded() == bytes(hex), "vector \(hex)")
    }
}

@Test func crcMatchesReferenceHeaderAndSeed() {
    #expect(DUMLCRC.crc8(bytes("551504")[...]) == 0xa9)
    #expect(DUMLCRC.crc16(bytes("551504a9")[...]) == 0xdf0c)
}

@Test func parserDecodesGoldenFrame() {
    var parser = DUMLParser()
    let frames = parser.feed(bytes(golden[0].1))
    #expect(frames == [golden[0].0.frame()])
    #expect(frames[0].commandSet == 0x04)
    #expect(frames[0].command == 0x0c)
}

@Test func parserHandlesFramesSplitAcrossChunks() {
    var parser = DUMLParser()
    let all = bytes(golden[0].1) + bytes(golden[3].1)
    var out: [DUMLFrame] = []
    for chunk in stride(from: 0, to: all.count, by: 5).map({ Array(all[$0..<min($0 + 5, all.count)]) }) {
        out += parser.feed(chunk)
    }
    #expect(out == [golden[0].0.frame(), golden[3].0.frame()])
}

@Test func parserResyncsAfterGarbageAndDropsBadCRC() {
    var parser = DUMLParser()
    var corrupted = bytes(golden[1].1)
    corrupted[corrupted.count - 1] ^= 0xFF
    let input: [UInt8] = [0x00, 0x55, 0x01, 0xAA] + corrupted + bytes(golden[2].1)
    #expect(parser.feed(input) == [golden[2].0.frame()])
}

@Test func parserNeverReturnsFramesFromRandomBytes() {
    var parser = DUMLParser()
    var seed: UInt64 = 0x1234_5678
    var noise: [UInt8] = []
    for _ in 0..<10_000 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        noise.append(UInt8(truncatingIfNeeded: seed >> 33))
    }
    #expect(parser.feed(noise).isEmpty)
}

@Test func roundTripPreservesFields() {
    let frame = DUMLFrame(sender: 0x04, receiver: 0x02, sequence: 513, commandType: 0x40,
                          commandSet: 0x05, command: 0x06, payload: [1, 2, 3, 4, 5])
    var parser = DUMLParser()
    #expect(parser.feed(frame.encoded()) == [frame])
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `git rm -q Tests/GimbalKitDJITests/Placeholder.swift; timeout 300 swift test --filter DUMLCodecTests 2>&1 | tail -10`
Expected: error `cannot find 'OMRotate' in scope`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKitDJI/DUMLCRC.swift`:
```swift
/// CRC de DUML. CRC8 (reflejado, poli 0x31 → 0x8C, semilla 0x77) sobre los 3 primeros bytes;
/// CRC16 (reflejado, poli 0x1021 → 0x8408, semilla 0x3692) sobre toda la trama anterior a la propia CRC.
enum DUMLCRC {
    static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var crc: UInt8 = 0x77
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1 }
        }
        return crc
    }

    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0x3692
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        }
        return crc
    }
}
```
`Sources/GimbalKitDJI/DUMLFrame.swift`:
```swift
public struct DUMLFrame: Sendable, Equatable {
    public var sender: UInt8
    public var receiver: UInt8
    public var sequence: UInt16
    public var commandType: UInt8
    public var commandSet: UInt8
    public var command: UInt8
    public var payload: [UInt8]

    public init(sender: UInt8, receiver: UInt8, sequence: UInt16, commandType: UInt8,
                commandSet: UInt8, command: UInt8, payload: [UInt8]) {
        self.sender = sender
        self.receiver = receiver
        self.sequence = sequence
        self.commandType = commandType
        self.commandSet = commandSet
        self.command = command
        self.payload = payload
    }

    /// 0x55, longitud (10 bits) + versión, CRC8, 7 bytes de cabecera, carga, CRC16 (LE).
    public func encoded() -> [UInt8] {
        let total = 11 + payload.count + 2
        var out: [UInt8] = [0x55, UInt8(total & 0xFF), UInt8((total >> 8) & 0x03) | 0x04]
        out.append(DUMLCRC.crc8(out[0..<3]))
        out += [sender, receiver, UInt8(sequence & 0xFF), UInt8(sequence >> 8), commandType, commandSet, command]
        out += payload
        let crc = DUMLCRC.crc16(out[0...])
        out += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return out
    }
}

public struct DUMLParser {
    private var buffer: [UInt8] = []

    public init() {}

    /// Acumula bytes y devuelve las tramas completas con CRC válido. Descarta basura y tramas corruptas.
    public mutating func feed(_ data: [UInt8]) -> [DUMLFrame] {
        buffer += data
        var frames: [DUMLFrame] = []
        while true {
            guard let start = buffer.firstIndex(of: 0x55) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 4 else { break }
            let total = Int(buffer[1]) | (Int(buffer[2] & 0x03) << 8)
            guard total >= 13, buffer[3] == DUMLCRC.crc8(buffer[0..<3]) else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= total else { break }
            let raw = Array(buffer[0..<total])
            let expected = UInt16(raw[total - 2]) | (UInt16(raw[total - 1]) << 8)
            guard DUMLCRC.crc16(raw[0..<(total - 2)]) == expected else {
                buffer.removeFirst()
                continue
            }
            frames.append(DUMLFrame(
                sender: raw[4], receiver: raw[5],
                sequence: UInt16(raw[6]) | (UInt16(raw[7]) << 8),
                commandType: raw[8], commandSet: raw[9], command: raw[10],
                payload: Array(raw[11..<(total - 2)])
            ))
            buffer.removeFirst(total)
        }
        return frames
    }
}
```
`Sources/GimbalKitDJI/OMRotate.swift`:
```swift
/// Orden de giro de la serie OM (cmd_set 0x04). Unidades crudas del protocolo; la conversión a grados es del driver.
public struct OMRotate: Sendable, Equatable {
    public enum Mode: UInt8, Sendable {
        case relative = 0x04
        case absolute = 0x05
        case speed = 0x80
    }

    public var yaw: Int16
    public var pitch: Int16
    public var roll: Int16
    public var time: UInt8
    public var mode: Mode

    public init(yaw: Int16, pitch: Int16, roll: Int16, time: UInt8, mode: Mode) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.time = time
        self.mode = mode
    }

    public func frame(sequence: UInt16 = 1) -> DUMLFrame {
        func le(_ value: Int16) -> [UInt8] {
            let raw = UInt16(bitPattern: value)
            return [UInt8(raw & 0xFF), UInt8(raw >> 8)]
        }
        return DUMLFrame(
            sender: 0x02, receiver: 0x04, sequence: sequence, commandType: 0x00, commandSet: 0x04,
            command: mode == .speed ? 0x0C : 0x14,
            payload: le(yaw) + le(roll) + le(pitch) + [mode.rawValue, time]
        )
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `timeout 300 swift test --filter DUMLCodecTests 2>&1 | tail -10`
Expected: `Test run with 7 tests passed`. Si falla algún vector, **no cambiar el vector**: comparar contra `docs/research/` y el código de referencia.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: códec DUML con vectores de oro y orden de giro OM"
```

---

### Task 4: Política de seguridad, lease y registro

**Files:**
- Create: `Sources/GimbalKit/SafetyPolicy.swift`, `Sources/GimbalKit/Lease.swift`, `Sources/GimbalKit/Audit.swift`
- Test: `Tests/GimbalKitTests/SafetyTests.swift`

**Interfaces:**
- Consumes: `Zone`, `Pose`, `ControlSource`, `Capabilities` (Task 1).
- Produces: `SafetyPolicy { maxSpeed: Double; maxLeaseSeconds: Double; deadmanSeconds: Double; zones: [Zone]; static let `default`; func zone(named: String) -> Zone?; func forbiddenZone(containing: Pose) -> Zone? }`; `enum SafetyViolation: Error, Equatable { speedTooHigh(limit: Double, requested: Double), noLease, leaseExpired, unknownZone(String), forbiddenZone(String), outsideZone(String), leaseTooLong(max: Double), invalidDuration, invalidValue, busy(holder: ControlSource), unsupported(Capabilities), poseUnavailable }`; `struct Lease: Sendable, Equatable { id: UUID; source: ControlSource; zone: String; expiresAt: Date }`; `struct AuditEntry`, `actor AuditLog { init(capacity: Int = 1000); record(_:); entries() -> [AuditEntry] }`.

- [ ] **Step 1: Escribir la prueba que falla**

`Tests/GimbalKitTests/SafetyTests.swift`:
```swift
import Foundation
import Testing
@testable import GimbalKit

@Test func policyFindsZonesByName() {
    let policy = SafetyPolicy(maxSpeed: 60, maxLeaseSeconds: 30, deadmanSeconds: 0.5, zones: [
        Zone(name: "mesa", yaw: -30...30, pitch: -20...20),
        Zone(name: "baño", yaw: 120...180, pitch: -90...90, forbidden: true),
    ])
    #expect(policy.zone(named: "mesa")?.name == "mesa")
    #expect(policy.zone(named: "nada") == nil)
    #expect(policy.forbiddenZone(containing: Pose(yaw: 150, pitch: 0))?.name == "baño")
    #expect(policy.forbiddenZone(containing: Pose(yaw: 0, pitch: 0)) == nil)
}

@Test func defaultPolicyIsConservative() {
    let policy = SafetyPolicy.default
    #expect(policy.maxSpeed == 60)
    #expect(policy.maxLeaseSeconds == 30)
    #expect(policy.deadmanSeconds == 0.5)
    #expect(policy.zones.isEmpty)
}

@Test func auditLogKeepsOnlyLatestEntriesUpToCapacity() async {
    let log = AuditLog(capacity: 3)
    for i in 0..<5 {
        await log.record(AuditEntry(date: Date(timeIntervalSince1970: Double(i)), source: .app,
                                    event: "e\(i)", outcome: .accepted))
    }
    let events = await log.entries().map(\.event)
    #expect(events == ["e2", "e3", "e4"])
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `timeout 300 swift test --filter SafetyTests 2>&1 | tail -10`
Expected: error `cannot find 'SafetyPolicy' in scope`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKit/SafetyPolicy.swift`:
```swift
public struct SafetyPolicy: Sendable, Equatable {
    public var maxSpeed: Double
    public var maxLeaseSeconds: Double
    public var deadmanSeconds: Double
    public var zones: [Zone]

    public init(maxSpeed: Double, maxLeaseSeconds: Double, deadmanSeconds: Double, zones: [Zone]) {
        self.maxSpeed = maxSpeed
        self.maxLeaseSeconds = maxLeaseSeconds
        self.deadmanSeconds = deadmanSeconds
        self.zones = zones
    }

    public static let `default` = SafetyPolicy(maxSpeed: 60, maxLeaseSeconds: 30, deadmanSeconds: 0.5, zones: [])

    public func zone(named name: String) -> Zone? {
        zones.first { $0.name == name }
    }

    public func forbiddenZone(containing pose: Pose) -> Zone? {
        zones.first { $0.forbidden && $0.contains(pose) }
    }
}

public enum SafetyViolation: Error, Equatable {
    case speedTooHigh(limit: Double, requested: Double)
    case noLease
    case leaseExpired
    case unknownZone(String)
    case forbiddenZone(String)
    case outsideZone(String)
    case leaseTooLong(max: Double)
    case invalidDuration
    case invalidValue
    case busy(holder: ControlSource)
    case unsupported(Capabilities)
    case poseUnavailable
}
```
`Sources/GimbalKit/Lease.swift`:
```swift
import Foundation

public struct Lease: Sendable, Equatable {
    public let id: UUID
    public let source: ControlSource
    public let zone: String
    public let expiresAt: Date

    public init(id: UUID = UUID(), source: ControlSource, zone: String, expiresAt: Date) {
        self.id = id
        self.source = source
        self.zone = zone
        self.expiresAt = expiresAt
    }
}
```
`Sources/GimbalKit/Audit.swift`:
```swift
import Foundation

public struct AuditEntry: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case accepted
        case rejected(String)
    }

    public let date: Date
    public let source: ControlSource?
    public let event: String
    public let outcome: Outcome

    public init(date: Date, source: ControlSource?, event: String, outcome: Outcome) {
        self.date = date
        self.source = source
        self.event = event
        self.outcome = outcome
    }
}

public actor AuditLog {
    private let capacity: Int
    private var stored: [AuditEntry] = []

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    public func record(_ entry: AuditEntry) {
        stored.append(entry)
        if stored.count > capacity { stored.removeFirst(stored.count - capacity) }
    }

    public func entries() -> [AuditEntry] { stored }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `timeout 300 swift test --filter SafetyTests 2>&1 | tail -8`
Expected: `Test run with 3 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: política de seguridad, lease y registro de auditoría"
```

---

### Task 5: GimbalController — leases, turno de control y validación

**Files:**
- Create: `Sources/GimbalKit/GimbalController.swift`
- Test: `Tests/GimbalKitTests/Fixtures.swift`, `Tests/GimbalKitTests/ControllerTests.swift`

**Interfaces:**
- Consumes: todo lo de las tareas 1, 2 y 4 (`SimGimbal`, `ManualClock`, `SafetyPolicy`, `SafetyViolation`, `Lease`, `AuditLog`).
- Produces: `public actor GimbalController { init(device: any GimbalDevice, policy: SafetyPolicy, now: @escaping @Sendable () -> Date = Date.init, audit: AuditLog = AuditLog()); let audit: AuditLog; var activeLease: Lease? { get }; func requestLease(source: ControlSource, zone: String, seconds: Double) async throws -> Lease; func send(_ command: MoveCommand, source: ControlSource, lease: Lease? = nil) async throws }`. En la Task 6 se añaden `stop`, `tick` y `deviceDisconnected` (y `revokeLease` privado).

- [ ] **Step 1: Escribir los fixtures y las pruebas que fallan**

`Tests/GimbalKitTests/Fixtures.swift`:
```swift
import Foundation
import GimbalKit
import GimbalKitSim

let deskZone = Zone(name: "mesa", yaw: -30...30, pitch: -20...20)
let doorZone = Zone(name: "puerta", yaw: 60...90, pitch: -10...10)
let wideZone = Zone(name: "ancha", yaw: -180...180, pitch: -90...90)
let bathZone = Zone(name: "baño", yaw: 120...180, pitch: -90...90, forbidden: true)

func makePolicy(zones: [Zone] = [deskZone, doorZone, wideZone, bathZone]) -> SafetyPolicy {
    SafetyPolicy(maxSpeed: 60, maxLeaseSeconds: 30, deadmanSeconds: 0.5, zones: zones)
}

func makeController(
    capabilities: Capabilities = [.speedControl, .absoluteControl, .poseFeedback],
    zones: [Zone] = [deskZone, doorZone, wideZone, bathZone]
) -> (controller: GimbalController, sim: SimGimbal, clock: ManualClock) {
    let sim = SimGimbal(capabilities: capabilities)
    let clock = ManualClock()
    let controller = GimbalController(device: sim, policy: makePolicy(zones: zones), now: { clock.now() })
    return (controller, sim, clock)
}
```
`Tests/GimbalKitTests/ControllerTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit
import GimbalKitSim

private let agent = ControlSource.agent("claude")

@Test func leaseRejectsUnknownForbiddenAndInvalidRequests() async {
    let (c, _, _) = makeController()
    await #expect(throws: SafetyViolation.unknownZone("cocina")) { try await c.requestLease(source: agent, zone: "cocina", seconds: 5) }
    await #expect(throws: SafetyViolation.forbiddenZone("baño")) { try await c.requestLease(source: agent, zone: "baño", seconds: 5) }
    await #expect(throws: SafetyViolation.leaseTooLong(max: 30)) { try await c.requestLease(source: agent, zone: "mesa", seconds: 31) }
    for bad in [0.0, -1.0, .nan, .infinity] {
        await #expect(throws: SafetyViolation.invalidDuration) { try await c.requestLease(source: agent, zone: "mesa", seconds: bad) }
    }
}

@Test func emptyZoneListRejectsEveryLease() async {
    let (c, _, _) = makeController(zones: [])
    await #expect(throws: SafetyViolation.unknownZone("mesa")) { try await c.requestLease(source: agent, zone: "mesa", seconds: 5) }
}

@Test func agentNeedsLeaseToMove() async throws {
    let (c, sim, _) = makeController()
    await #expect(throws: SafetyViolation.noLease) {
        try await c.send(.absolute(Pose(yaw: 10, pitch: 0), seconds: 1), source: agent)
    }
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 5)
    try await c.send(.absolute(Pose(yaw: 10, pitch: 0), seconds: 1), source: agent, lease: lease)
    #expect(await sim.currentPose() == Pose(yaw: 10, pitch: 0))
}

@Test func absoluteOutsideZoneOrIntoForbiddenZoneIsRejected() async throws {
    let (c, sim, _) = makeController()
    let desk = try await c.requestLease(source: agent, zone: "mesa", seconds: 5)
    await #expect(throws: SafetyViolation.outsideZone("mesa")) {
        try await c.send(.absolute(Pose(yaw: 80, pitch: 0), seconds: 1), source: agent, lease: desk)
    }
    let wide = try await c.requestLease(source: agent, zone: "ancha", seconds: 5)
    await #expect(throws: SafetyViolation.forbiddenZone("baño")) {
        try await c.send(.absolute(Pose(yaw: 150, pitch: 0), seconds: 1), source: agent, lease: wide)
    }
    #expect(await sim.commands.isEmpty)
}

@Test func speedAndPoseValuesAreValidated() async throws {
    let (c, sim, _) = makeController()
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 5)
    await #expect(throws: SafetyViolation.speedTooHigh(limit: 60, requested: 90)) {
        try await c.send(.speed(yaw: 90, pitch: 0, roll: 0), source: agent, lease: lease)
    }
    await #expect(throws: SafetyViolation.invalidValue) {
        try await c.send(.speed(yaw: .nan, pitch: 0, roll: 0), source: agent, lease: lease)
    }
    await #expect(throws: SafetyViolation.invalidValue) {
        try await c.send(.absolute(Pose(yaw: .infinity, pitch: 0), seconds: 1), source: agent, lease: lease)
    }
    await #expect(throws: SafetyViolation.invalidValue) {
        try await c.send(.absolute(Pose(yaw: 0, pitch: 0), seconds: .nan), source: agent, lease: lease)
    }
    #expect(await sim.commands.isEmpty)
}

@Test func privilegedSourceStillRespectsSpeedLimitButNeedsNoLease() async throws {
    let (c, sim, _) = makeController()
    try await c.send(.speed(yaw: 30, pitch: 0, roll: 0), source: .app)
    await #expect(throws: SafetyViolation.speedTooHigh(limit: 60, requested: 61)) {
        try await c.send(.speed(yaw: 61, pitch: 0, roll: 0), source: .app)
    }
    #expect(await sim.commands.count == 1)
}

@Test func secondAgentGetsBusyUntilLeaseExpires() async throws {
    let (c, _, clock) = makeController()
    _ = try await c.requestLease(source: agent, zone: "mesa", seconds: 10)
    await #expect(throws: SafetyViolation.busy(holder: agent)) {
        try await c.requestLease(source: .agent("otro"), zone: "puerta", seconds: 5)
    }
    clock.advance(11)
    let second = try await c.requestLease(source: .agent("otro"), zone: "puerta", seconds: 5)
    #expect(second.zone == "puerta")
}

@Test func expiredLeaseIsReportedAsExpired() async throws {
    let (c, _, clock) = makeController()
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 5)
    clock.advance(6)
    await #expect(throws: SafetyViolation.leaseExpired) {
        try await c.send(.absolute(Pose(yaw: 0, pitch: 0), seconds: 1), source: agent, lease: lease)
    }
}

@Test func privilegedSourcePreemptsAgentLeaseAndStopsMotors() async throws {
    let (c, sim, _) = makeController()
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 20)
    try await c.send(.speed(yaw: 10, pitch: 0, roll: 0), source: agent, lease: lease)
    _ = try await c.requestLease(source: .app, zone: "puerta", seconds: 10)
    #expect(await sim.commands.last == .stop)
    await #expect(throws: SafetyViolation.noLease) {
        try await c.send(.speed(yaw: 10, pitch: 0, roll: 0), source: agent, lease: lease)
    }
}

@Test func speedNeedsPoseFeedbackForAgents() async throws {
    let (c, _, _) = makeController(capabilities: [.speedControl])
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 5)
    await #expect(throws: SafetyViolation.poseUnavailable) {
        try await c.send(.speed(yaw: 10, pitch: 0, roll: 0), source: agent, lease: lease)
    }
}

@Test func unsupportedCommandsAreRejected() async {
    let (c, _, _) = makeController(capabilities: [.speedControl])
    await #expect(throws: SafetyViolation.unsupported(.absoluteControl)) {
        try await c.send(.absolute(Pose(), seconds: 1), source: .app)
    }
}

@Test func stopIsAlwaysAllowedAndRejectionsAreAudited() async throws {
    let (c, sim, _) = makeController()
    try await c.send(.stop, source: agent)
    #expect(await sim.commands == [.stop])
    _ = try? await c.send(.speed(yaw: 1, pitch: 0, roll: 0), source: agent)
    let entries = await c.audit.entries()
    #expect(entries.contains { $0.outcome == .rejected("noLease") })
    #expect(entries.contains { $0.outcome == .accepted })
}

@Test func concurrentLeaseRequestsGrantExactlyOne() async {
    let (c, _, _) = makeController()
    let granted = await withTaskGroup(of: Bool.self) { group in
        for i in 0..<8 {
            group.addTask { (try? await c.requestLease(source: .agent("a\(i)"), zone: "mesa", seconds: 5)) != nil }
        }
        var n = 0
        for await ok in group where ok { n += 1 }
        return n
    }
    #expect(granted == 1)
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `timeout 300 swift test --filter ControllerTests 2>&1 | tail -10`
Expected: error `cannot find 'GimbalController' in scope`.

- [ ] **Step 3: Implementar**

`Sources/GimbalKit/GimbalController.swift`:
```swift
import Foundation

public actor GimbalController {
    private let device: any GimbalDevice
    private let policy: SafetyPolicy
    private let now: @Sendable () -> Date
    public let audit: AuditLog

    private var lease: Lease?
    private var movingBySpeed = false
    private var lastSpeedAt: Date?

    public init(
        device: any GimbalDevice,
        policy: SafetyPolicy,
        now: @escaping @Sendable () -> Date = { Date() },
        audit: AuditLog = AuditLog()
    ) {
        self.device = device
        self.policy = policy
        self.now = now
        self.audit = audit
    }

    /// El lease vigente (nil si no hay o ya caducó).
    public var activeLease: Lease? {
        guard let lease, lease.expiresAt > now() else { return nil }
        return lease
    }

    // MARK: Leases

    public func requestLease(source: ControlSource, zone name: String, seconds: Double) async throws -> Lease {
        do {
            guard seconds.isFinite, seconds > 0 else { throw SafetyViolation.invalidDuration }
            guard seconds <= policy.maxLeaseSeconds else { throw SafetyViolation.leaseTooLong(max: policy.maxLeaseSeconds) }
            guard let zone = policy.zone(named: name) else { throw SafetyViolation.unknownZone(name) }
            guard !zone.forbidden else { throw SafetyViolation.forbiddenZone(name) }
            if let active = activeLease, active.source != source {
                guard source.isPrivileged else { throw SafetyViolation.busy(holder: active.source) }
                await revokeLease(reason: "preempted by \(source)")
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

    // MARK: Órdenes

    public func send(_ command: MoveCommand, source: ControlSource, lease presented: Lease? = nil) async throws {
        do {
            try await validate(command, source: source, presented: presented)
            try await device.send(command)
            switch command {
            case let .speed(yaw, pitch, roll):
                movingBySpeed = !(yaw == 0 && pitch == 0 && roll == 0)
                lastSpeedAt = now()
            case .absolute, .stop:
                movingBySpeed = false
            }
            await record(source, "\(command)", .accepted)
        } catch {
            await record(source, "\(command)", .rejected(Self.describe(error)))
            throw error
        }
    }

    private func validate(_ command: MoveCommand, source: ControlSource, presented: Lease?) async throws {
        if case .stop = command { return }
        let caps = device.capabilities
        switch command {
        case let .speed(yaw, pitch, roll):
            guard caps.contains(.speedControl) else { throw SafetyViolation.unsupported(.speedControl) }
            guard yaw.isFinite, pitch.isFinite, roll.isFinite else { throw SafetyViolation.invalidValue }
            let peak = max(abs(yaw), abs(pitch), abs(roll))
            guard peak <= policy.maxSpeed else { throw SafetyViolation.speedTooHigh(limit: policy.maxSpeed, requested: peak) }
        case let .absolute(pose, seconds):
            guard caps.contains(.absoluteControl) else { throw SafetyViolation.unsupported(.absoluteControl) }
            guard pose.isFinite, seconds.isFinite, seconds >= 0 else { throw SafetyViolation.invalidValue }
        case .stop:
            return
        }
        if source.isPrivileged { return }

        guard let active = activeLease else {
            throw presented == nil ? SafetyViolation.noLease : SafetyViolation.leaseExpired
        }
        guard presented?.id == active.id, active.source == source else { throw SafetyViolation.noLease }
        guard let zone = policy.zone(named: active.zone) else { throw SafetyViolation.unknownZone(active.zone) }

        switch command {
        case let .absolute(pose, _):
            if let forbidden = policy.forbiddenZone(containing: pose) { throw SafetyViolation.forbiddenZone(forbidden.name) }
            guard zone.contains(pose) else { throw SafetyViolation.outsideZone(zone.name) }
        case .speed:
            guard caps.contains(.poseFeedback), let pose = await device.currentPose() else { throw SafetyViolation.poseUnavailable }
            if let forbidden = policy.forbiddenZone(containing: pose) { throw SafetyViolation.forbiddenZone(forbidden.name) }
            guard zone.contains(pose) else { throw SafetyViolation.outsideZone(zone.name) }
        case .stop:
            break
        }
    }

    // MARK: Utilidades internas (las usa también la Task 6)

    func revokeLease(reason: String) async {
        let source = lease?.source
        lease = nil
        try? await device.send(.stop)
        movingBySpeed = false
        await record(source, "lease revoked: \(reason)", .accepted)
    }

    func record(_ source: ControlSource?, _ event: String, _ outcome: AuditEntry.Outcome) async {
        await audit.record(AuditEntry(date: now(), source: source, event: event, outcome: outcome))
    }

    static func describe(_ error: any Error) -> String {
        if let violation = error as? SafetyViolation {
            // Solo el nombre del caso, sin argumentos: p. ej. "noLease", "speedTooHigh".
            return String(String(describing: violation).prefix { $0 != "(" })
        }
        return String(describing: error)
    }
}
```

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `timeout 300 swift test --filter ControllerTests 2>&1 | tail -15`
Expected: `Test run with 13 tests passed`. Si algún test de errores falla por diferencias de comparación, ajustar el **código**, no la expectativa.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: GimbalController con leases, turno de control y validación"
```

---

### Task 6: Deadman, parada y desconexión

**Files:**
- Modify: `Sources/GimbalKit/GimbalController.swift` (añadir `stop`, `tick`, `deviceDisconnected`)
- Test: `Tests/GimbalKitTests/DeadmanTests.swift`

**Interfaces:**
- Consumes: `GimbalController` (Task 5, incluidos `revokeLease(reason:)` y `record(_:_:_:)`).
- Produces: `func stop(source: ControlSource) async`, `func tick() async`, `func deviceDisconnected() async`. El host (Plan 2) llamará a `tick()` cada ≤100 ms mientras haya movimiento.

- [ ] **Step 1: Escribir la prueba que falla**

`Tests/GimbalKitTests/DeadmanTests.swift`:
```swift
import Foundation
import Testing
import GimbalKit
import GimbalKitSim

private let agent = ControlSource.agent("claude")

@Test func deadmanStopsMotionWhenCommandsStopArriving() async throws {
    let (c, sim, clock) = makeController()
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 20)
    try await c.send(.speed(yaw: 10, pitch: 0, roll: 0), source: agent, lease: lease)
    clock.advance(0.4)
    await c.tick()
    #expect(await sim.commands.last == .speed(yaw: 10, pitch: 0, roll: 0))
    clock.advance(0.2)
    await c.tick()
    #expect(await sim.commands.last == .stop)
}

@Test func tickDoesNotSpamStopsWhenNothingMoves() async throws {
    let (c, sim, clock) = makeController()
    for _ in 0..<5 {
        clock.advance(1)
        await c.tick()
    }
    #expect(await sim.commands.isEmpty)
}

@Test func tickStopsWhenMotionLeavesLeasedZone() async throws {
    let (c, sim, _) = makeController()
    let lease = try await c.requestLease(source: agent, zone: "mesa", seconds: 20)
    try await c.send(.speed(yaw: 60, pitch: 0, roll: 0), source: agent, lease: lease)
    await sim.advance(seconds: 1)   // yaw 60 > 30: fuera de «mesa»
    await c.tick()
    #expect(await sim.commands.last == .stop)
}

@Test func tickRevokesExpiredLeaseAndStops() async throws {
    let (c, sim, clock) = makeController()
    _ = try await c.requestLease(source: agent, zone: "mesa", seconds: 5)
    clock.advance(6)
    await c.tick()
    #expect(await sim.commands.last == .stop)
    #expect(await c.activeLease == nil)
}

@Test func physicalStopRevokesAgentLeaseButAgentStopKeepsOthers() async throws {
    let (c, sim, _) = makeController()
    _ = try await c.requestLease(source: agent, zone: "mesa", seconds: 20)
    await c.stop(source: .agent("otro"))
    #expect(await c.activeLease != nil)
    await c.stop(source: .physical)
    #expect(await c.activeLease == nil)
    #expect(await sim.commands.filter { $0 == .stop }.count == 2)
}

@Test func disconnectClearsLeaseAndIsAudited() async throws {
    let (c, _, _) = makeController()
    _ = try await c.requestLease(source: agent, zone: "mesa", seconds: 20)
    await c.deviceDisconnected()
    #expect(await c.activeLease == nil)
    #expect(await c.audit.entries().contains { $0.event == "device disconnected" })
}

@Test func stopStillWorksWhenDeviceFails() async {
    let (c, sim, _) = makeController()
    await sim.failNextSend(with: Boom())
    await c.stop(source: .app)          // no debe lanzar ni colgarse
    #expect(await c.audit.entries().contains { $0.event == "stop" })
}
```

- [ ] **Step 2: Ejecutar y comprobar que falla**

Run: `timeout 300 swift test --filter DeadmanTests 2>&1 | tail -10`
Expected: error `value of type 'GimbalController' has no member 'tick'`.

- [ ] **Step 3: Implementar**

Añadir a `GimbalController` (antes de `// MARK: Utilidades internas`):
```swift
    // MARK: Parada, deadman y desconexión

    /// Siempre envía parada. Una fuente privilegiada además revoca el lease; otra solo el suyo.
    public func stop(source: ControlSource) async {
        try? await device.send(.stop)
        movingBySpeed = false
        if source.isPrivileged || lease?.source == source { lease = nil }
        await record(source, "stop", .accepted)
    }

    /// Debe llamarse con frecuencia (≤100 ms) mientras haya movimiento. Aplica caducidad de lease,
    /// deadman y salida de zona.
    public func tick() async {
        let t = now()
        if let lease, lease.expiresAt <= t {
            await revokeLease(reason: "expired")
            return
        }
        guard movingBySpeed else { return }
        if let last = lastSpeedAt, t.timeIntervalSince(last) > policy.deadmanSeconds {
            await emergencyStop("deadman")
            return
        }
        if let lease, !lease.source.isPrivileged,
           let zone = policy.zone(named: lease.zone),
           let pose = await device.currentPose(),
           !zone.contains(pose) || policy.forbiddenZone(containing: pose) != nil {
            await emergencyStop("left zone")
        }
    }

    public func deviceDisconnected() async {
        lease = nil
        movingBySpeed = false
        await record(nil, "device disconnected", .accepted)
    }

    private func emergencyStop(_ reason: String) async {
        try? await device.send(.stop)
        movingBySpeed = false
        await record(nil, "emergency stop: \(reason)", .accepted)
    }
```
Añadir al inicio de `Tests/GimbalKitTests/DeadmanTests.swift`, si `Boom` no es visible desde `SimGimbalTests.swift` (mismo target: sí lo es; no duplicar).

- [ ] **Step 4: Ejecutar y comprobar que pasa**

Run: `timeout 300 swift test --filter DeadmanTests 2>&1 | tail -12`
Expected: `Test run with 7 tests passed`.

- [ ] **Step 5: Suite completa y commit**

Run: `timeout 300 swift test 2>&1 | tail -6`
Expected: todas las pruebas pasan (Task 1: 4, Task 2: 5, Task 3: 7, Task 4: 3, Task 5: 13, Task 6: 7 = 39).
Run: `timeout 300 swift build -c release 2>&1 | tail -3` → `Build complete!`

```bash
git add -A && git commit -m "feat: deadman, parada y desconexión en el controlador"
```

---

### Task 7: Documentación del tramo y estado

**Files:**
- Modify: `README.md`
- Create: `docs/superpowers/plans/ESTADO.md`

- [ ] **Step 1: README**

Sustituir `README.md` por: qué es (2 frases), módulos (`GimbalKit`, `GimbalKitSim`, `GimbalKitDJI`) con una línea cada uno, un ejemplo de uso con `SimGimbal` y `GimbalController` (crear lease, mover, parar), cómo ejecutar las pruebas (`swift test`), la nota «no afiliado a DJI» y el enlace a la spec y al `NOTICE`.

- [ ] **Step 2: ESTADO.md**

Crear `docs/superpowers/plans/ESTADO.md` con la tabla: M0, M1 y M3 «hecho (Plan 1)»; M2, M4, M5, M6 «pendiente»; y la lista de lo que se sabe que falta para el Plan 2: (1) driver CoreBluetooth que recupere la Osmo ya conectada por `retrieveConnectedPeripherals([FFF0])`, (2) conversión de unidades crudas ↔ grados medida con hardware, (3) decodificar la telemetría `0x04/0x57` y `0x04/0x05`, (4) **validar el parser contra tramas reales de la SE** (el CRC se comprobó con el código de referencia, no con capturas), (5) host macOS + MCP.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "docs: README y estado del plan 1"
```

---

## Autorrevisión

- **Cobertura de la spec:** §4 núcleo (Types, SafetyPolicy, ControlArbiter+Lease dentro de `GimbalController`, AuditLog, fallos) → tareas 1, 4, 5, 6. §5 códec con vectores de oro y CRC → tarea 3 (`OMConnection` queda para el Plan 2, a propósito). §8 pruebas contra el simulador → tareas 2, 5, 6. Hitos M0, M1, M3 cubiertos; M2, M4, M5, M6 son planes siguientes.
- **Marcadores:** ninguno; cada paso lleva el código completo.
- **Consistencia de tipos:** `MoveCommand`, `ControlSource`, `Lease`, `SafetyViolation`, `Capabilities`, `Pose` y los nombres `requestLease/send/stop/tick/deviceDisconnected/revokeLease/record` coinciden entre tareas. `Boom` se define en `SimGimbalTests.swift` y se reutiliza en `DeadmanTests.swift` (mismo target).
- **Review Focus:** NaN/infinitos → `invalidValue` (tarea 5); duración inválida → `invalidDuration` (tarea 5); dos agentes simultáneos → prueba de `TaskGroup` (tarea 5); parser con basura, trozos y CRC corrupto → tarea 3; sin spam de paradas y zona vacía → tareas 6 y 5.
