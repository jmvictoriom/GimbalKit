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
