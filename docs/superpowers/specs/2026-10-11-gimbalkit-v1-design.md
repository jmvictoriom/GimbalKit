# GimbalKit v1 — diseño

Estado: aprobada por delegación de Jesús (2026-10-11). Decisiones de diseño: autoaprobadas por Claude;
publicar fuera, cuentas y dinero: se consultan.

## 1. Qué es

Una librería Swift y dos apps que convierten un estabilizador de móvil barato (DJI Osmo Mobile SE) en un
pan-tilt programable que entienden **Siri/Atajos** y **agentes de IA (MCP)**, con la seguridad en un solo sitio.
Código abierto (MIT), sin dependencias de pago, sin coste por uso. Nombre sin «Osmo» ni «DJI».

### Éxito de la v1
1. Desde un Atajo del iPhone: «Mira a [zona]» y «Para» mueven la Osmo SE.
2. Desde Claude Code (Mac): una llamada MCP `gimbal_look` mueve la Osmo y devuelve el estado.
3. Ninguna fachada puede saltarse los límites, el turno de control ni las zonas prohibidas.
4. Todo el núcleo se prueba sin hardware con el simulador.

### Fuera de la v1
DockKit, varias cámaras, VISCA/NDI/OSC/MQTT, RoomPlan, aprendizaje, imagen de la cámara en MCP, Apple Watch,
Vision Pro. (Quedan anotados en el backlog; ninguna decisión de v1 debe impedirlos.)

## 2. Hechos medidos (no suposiciones)

Fuente: `docs/research/` y el repo MIT `alkersan/om-research` (probado en OM2/OM3/OM4; la SE se ha verificado
aquí: se movió desde WebBluetooth y desde Python/CoreBluetooth en el Mac).

- La SE anuncia un servicio `FFF0` con `FFF4` (notify), `FFF5` (write sin respuesta) y `FFF3` (notify+write,
  sin documentar); además `FF61` (sin explorar) y Device Information `180A`. MTU 247.
- Nombre del dispositivo: configurable por el usuario («OMSE-jesus»). No sirve para identificar el modelo.
- **La SE queda conectada al sistema como HID BLE.** Un escaneo no la ve; hay que recuperarla con
  `retrieveConnectedPeripherals(withServices: [FFF0])` y, si no está conectada, escanear por servicio.
- Protocolo: tramas DUML (`0x55`, longitud 10 bits, CRC8 de cabecera, CRC16 final). Orden de giro conocida:
  yaw/pitch/roll en Int16 LE, modos `RELATIVE 0x04`, `ABSOLUTE 0x05`, `SPEED 0x80`, tiempo en décimas.
- Telemetría recibida sin pedirla (~47 msg/s): `0x04/0x57` (probable joystick/botones), `0x04/0x05`
  (probable orientación, valores tipo cuaternión), `0x05/0x06` (batería: `payload[0]`=%, último byte=carga).
  **Las interpretaciones de 0x57 y 0x04/0x05 son hipótesis hasta decodificarlas (hito M2).**

## 3. Arquitectura

Decisión: **una app anfitriona es la única dueña de la Osmo; el resto son clientes finos** (enfoque B).
Un servidor MCP por stdio lo lanza el cliente como proceso hijo sin permiso de Bluetooth, y dos procesos no
pueden compartir la conexión; por eso el dueño es una app, y MCP/CLI hablan con ella.

```
GimbalKit (núcleo, sin Bluetooth)   ← política de seguridad, turno de control, zonas, registro
   ├─ GimbalKitDJI   (driver OM: DUML + CoreBluetooth)
   ├─ GimbalKitSim   (simulador, misma interfaz)
   ├─ GimbalKitIntents (App Intents)            ← iOS y macOS
   └─ GimbalKitMCP   (servidor MCP, HTTP localhost)  ← macOS
Apps: GimbalHost-macOS (barra de menús + CLI `gimbal`)  ·  GimbalHost-iOS
```

- **macOS:** la app de barra de menús posee la conexión y la política. Sirve MCP (Streamable HTTP) en
  `127.0.0.1` con token local. La CLI usa el mismo API. Un puente stdio para Claude Desktop queda para después.
- **iOS:** la app posee la conexión; las acciones de Atajos se ejecutan en el proceso de la app. Sin MCP.
- Un `Package.swift` único con los módulos; las apps son proyectos finos que dependen del paquete.
- Swift 6 (modo de concurrencia estricto), `actor` para todo estado compartido, Swift Testing.

## 4. Núcleo (`GimbalKit`)

- `GimbalDevice` (protocolo): `capabilities`, `state` (AsyncStream), `move(_:)`, `stop()`. Las capacidades
  declaran qué sabe hacer cada soporte (velocidad, posición absoluta, posición leída, joystick, batería).
  Un soporte sin posición leída no puede cumplir `look(zona)` por ángulos: lo declara y la fachada lo rechaza.
- `Pose` (yaw/pitch/roll en grados), `Zone` (nombre, rangos de yaw/pitch, `forbidden: Bool`).
- `SafetyPolicy` (valor, no ajustes sueltos): velocidad máxima, aceleración máxima, `deadman` (si no llega una
  orden de velocidad en N ms, el soporte recibe parada), zonas prohibidas.
- `ControlArbiter` (actor): **un solo titular**; las demás fuentes esperan o se rechazan. Una fuente física
  (botón/joystick de la Osmo) y el botón de parada de la app tienen prioridad máxima.
- `Lease`: concesión acotada `{fuente, zona, duración}`; toda orden de un agente exige un lease vigente.
  Expira sola y devuelve el soporte a su posición segura.
- `AuditLog`: cada orden con fuente, zona, motivo y resultado; consultable y exportable.
- Comportamiento ante fallos: desconexión → parada y estado `disconnected`; orden fuera de política →
  rechazada con motivo tipado (nunca recortada en silencio).

## 5. Driver (`GimbalKitDJI`)

- `DUMLCodec`: codificar/decodificar tramas; pruebas con vectores de oro tomados de om-research y de las
  capturas propias (incluye verificar CRC8/CRC16 con los paquetes de referencia de sus comentarios).
- `OMConnection`: descubrimiento (recuperar conectado → escanear por `FFF0`), MTU, trozos de escritura,
  suscripción a `FFF4`/`FFF3`, reconexión con retroceso. Sin lógica de seguridad (eso es del núcleo).
- Reconoce solo las órdenes verificadas en hardware; el resto de mensajes se registra, no se interpreta.
- Atribución: derivado del trabajo MIT de `alkersan/om-research`; se cita en `NOTICE`.

## 6. Atajos (`GimbalKitIntents`)

`ZoneEntity` (AppEntity: zonas con nombre → Spotlight/Siri). Acciones v1:
**Mirar a zona**, **Mover (relativo)**, **Parar**, **Guardar zona aquí** (exige confirmación en pantalla),
**Estado**. Cada acción pasa por `ControlArbiter` + `SafetyPolicy`. Los Atajos son una fuente más, sin privilegios.
Riesgo: la reconexión BLE dentro del proceso de un intent en segundo plano; mitigación: spike temprano (M5) y,
si falla, `openAppWhenRun = true`.

## 7. MCP (`GimbalKitMCP`)

Herramientas v1: `gimbal_status`, `gimbal_zones`, `gimbal_look(zone, lease_seconds ≤ 30)`, `gimbal_stop`.
**Guardar o editar zonas no es una herramienta MCP**: requiere al humano. Toda orden de movimiento exige lease y
muestra aviso en la app (privacidad visible); sin lease no hay movimiento. Todo se registra en `AuditLog`.
Los resultados de herramienta son datos tipados; el servidor no acepta texto libre que cambie la política.

## 8. Pruebas

- Núcleo y política: pruebas unitarias contra `GimbalKitSim` (turno de control, expiración de leases, zonas
  prohibidas, deadman, desconexión, orden fuera de política).
- Códec: vectores de oro. Driver: manual con hardware (guion en `docs/`), no en CI.
- Fachadas: MCP con un cliente de prueba contra el simulador; Intents con pruebas de la lógica de acciones.
- Una sola compilación/suite Swift a la vez (carga del Mac); `timeout` por suite.

## 9. Riesgos

| Riesgo | Mitigación |
|---|---|
| Interpretación errónea de la telemetría | Hito de decodificación con movimiento manual antes de usarla |
| La Osmo no se anuncia (HID conectado) | Recuperación por servicio; cubierto en pruebas manuales |
| Intents en segundo plano | Spike M5; alternativa `openAppWhenRun` |
| Cambios de firmware de DJI | Driver aislado; capacidades declaradas; pruebas de humo por modelo |
| Marca y App Store | Sin «Osmo/DJI» en nombre ni icono; texto de interoperabilidad prudente |
| Privacidad con agentes | Lease, zonas prohibidas, confirmación local, privacidad visible, registro |

## 10. Hitos

- **M0** Repo, paquete, tipos del núcleo, simulador, CI local.
- **M1** `DUMLCodec` con vectores de oro.
- **M2** Driver sobre la SE en Mac + CLI mínima + decodificación de telemetría (con Jesús moviendo la Osmo).
- **M3** `SafetyPolicy`, `ControlArbiter`, `Lease`, `AuditLog` completos con pruebas.
- **M4** App macOS de barra de menús + servidor MCP + `gimbal` CLI.
- **M5** App iOS + `GimbalKitIntents` (incluye el spike de segundo plano).
- **M6** Documentación, `NOTICE`, guion de pruebas con hardware. Publicar (GitHub público) lo decide Jesús.
