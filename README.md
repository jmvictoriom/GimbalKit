# GimbalKit

GimbalKit es un paquete Swift para controlar estabilizadores de móvil con una política de seguridad común. Incluye un simulador para probar el núcleo sin hardware y un códec DUML para las órdenes de la serie OM.

Estado: en desarrollo.

## Módulos

- `GimbalKit`: tipos, política de seguridad, leases, turno de control, deadman y registro de auditoría.
- `GimbalKitSim`: dispositivo simulado y reloj manual para pruebas deterministas.
- `GimbalKitDJI`: CRC, codificación y parser DUML, y órdenes de giro en unidades crudas del protocolo.

## Ejemplo con el simulador

```swift
import GimbalKit
import GimbalKitSim

func runDemo() async throws {
    let sim = SimGimbal()
    let policy = SafetyPolicy(
        maxSpeed: 60,
        maxLeaseSeconds: 30,
        deadmanSeconds: 0.5,
        zones: [Zone(name: "mesa", yaw: -30...30, pitch: -20...20)]
    )
    let controller = GimbalController(device: sim, policy: policy)
    let source = ControlSource.agent("demo")
    let lease = try await controller.requestLease(source: source, zone: "mesa", seconds: 5)

    try await controller.send(
        .absolute(Pose(yaw: 10, pitch: 0), seconds: 1),
        source: source,
        lease: lease
    )
    await controller.stop(source: source)
}
```

El host debe llamar a `tick()` cada 100 ms o menos mientras haya movimiento para aplicar el deadman, la caducidad del lease y los límites de zona.

## Pruebas

```bash
swift test
```

El Plan 1 prueba el núcleo y el códec sin Bluetooth ni hardware. El driver CoreBluetooth y la validación con tramas reales de la SE quedan pendientes para el Plan 2.

GimbalKit no está afiliado a DJI. «DJI» y «Osmo» son marcas de sus propietarios.

[Especificación](docs/superpowers/specs/2026-10-11-gimbalkit-v1-design.md) · [Estado](docs/superpowers/plans/ESTADO.md) · [Atribución y NOTICE](NOTICE).
