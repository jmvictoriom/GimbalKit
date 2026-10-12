# Estado de GimbalKit

| Hito | Estado |
| --- | --- |
| M0 | hecho (Plan 1) |
| M1 | hecho (Plan 1) |
| M2 | pendiente |
| M3 | hecho (Plan 1) |
| M4 | pendiente |
| M5 | pendiente |
| M6 | pendiente |

Las 39 pruebas del Plan 1 pasan y la compilación release termina correctamente. Los cambios de las Tasks 2–7 quedan en el árbol de trabajo de `feat/plan-1`, pendientes de los commits que hará Claude.

Pendiente para el Plan 2:

1. Driver CoreBluetooth que recupere la Osmo ya conectada mediante `retrieveConnectedPeripherals(withServices: [FFF0])`.
2. Conversión de unidades crudas ↔ grados medida con hardware.
3. Decodificar la telemetría `0x04/0x57` y `0x04/0x05`.
4. **Validar el parser contra tramas reales de la SE**: el CRC se comprobó con el código de referencia, no con capturas.
5. Host macOS y MCP.

## Lecciones del Plan 1

- **Carrera parada/orden (corregida en la revisión):** el plan leía la pose con `await` *después* de comprobar el
  lease; un `stop(.physical)` concurrente se colaba y la orden de velocidad salía después de la parada. Ahora la pose se
  lee antes y la validación no tiene esperas hasta el envío; `stop` invalida el estado antes de avisar al dispositivo.
  Cubierto por `stopDuringPoseLookupCancelsTheInFlightSpeedCommand`. **Regla para el Plan 2:** el driver debe serializar
  las escrituras en orden de llegada y nunca reordenar una parada.
- Las fachadas (Atajos, MCP) construyen la `ControlSource`; el host debe garantizar que un agente jamás pueda pasar `.app`
  ni `.physical`.

## Plan 2 (2026-10-11): driver de la Osmo SE — HECHO

M2 completo y validado en hardware: telemetría real (cuaternión y batería), estimador de pose, conversión de unidades,
`OMDevice` y `CoreBluetoothOMTransport` (módulo `GimbalKitBLE`), prueba de humo `scripts/run-smoke.sh`. 59 pruebas. Medidas
en `docs/research/telemetria-om-se.md` (giro de +22° y vuelta a −0,013° con la librería).

Pendiente (Plan 3): controlador «ir a zona» en bucle cerrado sobre pose retardada (~1,5 Hz) y con órdenes cada ≥ 0,25 s;
joystick y botones por HID; app anfitriona de macOS (barra de menús) con servidor MCP y CLI; app iOS con Atajos.
Atención: el soporte declara `speedControl + poseFeedback + battery`; `absoluteControl` y `joystickInput` sin verificar.

## Plan 3 (2026-10-11): ir a zona, MCP HTTP, anfitrión macOS, CLI y GimbalLab — HECHO (salvo lo manual)

Implementado por Codex Sol (4 tandas + modo `--auto-run`), revisado por Claude. 121 pruebas pasando (4 de ellas abren sockets y solo
corren fuera del sandbox de Codex). GimbalLab validó en la Osmo: telemetría 1,0 Hz, reposo 0,0065°, batería, yaw +20,86° con vuelta
a 0,15°, parada con deriva 0,004° y `0x04/0x57` constante.

**Pendiente (manual):**
- Probar «ir a zona» en hardware: guardar una zona desde la app de barra de menús (confirmación humana) o con el Lab y medir la
  velocidad efectiva del navegador (simulación: ~0,65 °/s; plazo de 25 s ⇒ alcance ≈ 16°). Ajustar duración de los pulsos con datos.
- Probar la app de barra de menús (`scripts/build-host-mac.sh`), el servidor MCP con Claude real y la CLI `gimbal`.
- Joystick y botones (HID) sin resolver. iOS + Atajos = Plan 4.
Lecciones de hardware en `docs/research/telemetria-om-se.md` (órdenes SPEED de ~0,5 s, pose retrasada, firma por identificador).

## Plan 4 (2026-10-12): iPhone, Atajos y mando mínimo de Apple Watch — CÓDIGO HECHO (falta instalar y probar con los aparatos)

Plan reescrito tras 5 auditorías (la última, «SIN CRÍTICOS»): pasó de reescribir el núcleo de seguridad a ser ADITIVO (solo `MotionStopCounter` y `stopToken` opcional en
`HostRuntime.look`; `GimbalController`, `GotoNavigator`, `NavigationSafety` y `OMDevice` intactos). Implementado por Codex Sol en 3 tandas; 175 pruebas (4 abren loopback y solo corren fuera del sandbox de Codex);
`xcodegen generate` + `xcodebuild` compilan GimbalPhone (simulador iOS) y GimbalWatch (simulador watchOS). Fuente del proyecto: `Apps/project.yml`.

Alcance v1 del reloj: PARADA, «Mirar a zona», estado y lista de zonas (STOP siempre primero, silencio de 2 s tras cualquier STOP, un solo movimiento a la vez, parada si pierde el alcance).
Sin jog continuo ni pasos: se descartó tras tres auditorías con críticos de carrera. Atajos: Mirar a zona, Parar, Estado, Guardar zona aquí.

**Pendiente (manual, requiere a Jesús):** firma e instalación en iPhone y Apple Watch reales (cuenta de desarrollador: equipo de Xcode), prueba de Atajos/Siri, del mando del reloj y de la reconexión BLE en segundo plano;
probar «ir a zona» en la Osmo y medir la velocidad real del navegador (simulación ~0,65 °/s); app de barra de menús y MCP con Claude real; joystick/botones (HID).
Hallazgos medios de la quinta auditoría sin aplicar: el estado del reloj no se refresca solo con cambios de zonas/batería (se refresca al pedirlo).

## App de iPhone: rediseño neumórfico y funciones nuevas (2026-10-12)

Sistema de diseño neumórfico propio (`Apps/GimbalPhone/Neumorphism.swift`; claro y oscuro, acentos del icono). Nuevo: esfera de orientación en vivo, **mapa de zonas** (plano yaw/pitch con zonas, prohibidas y pose),
**borrar zonas** con confirmación (`HostRuntime.deleteZone`, único cambio del runtime), resultado claro tras «Mirar» (`LookOutcome`: llegó / ya estabas dentro / motivo real del fallo) y vibración.
193 pruebas (15 nuevas); núcleo de seguridad intacto. Verificado en simulador (claro/oscuro) e instalado en el iPhone.
