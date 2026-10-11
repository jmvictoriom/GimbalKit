# Telemetría y control de la Osmo Mobile SE (medido el 2026-10-11)

Hardware: Osmo Mobile SE (firmware sin comprobar), móvil montado, base sobre trípode. Capturas en `capturas/`
(`*.jsonl.gz`: una línea por trama, `{t, fase, crc, hex}`; scripts `captura_guiada.py` y `captura_motores.py`).

## Verificado

| Hecho | Evidencia |
|---|---|
| El parser DUML (CRC8+CRC16 estándar) valida tramas reales de la SE | 5548 tramas pasivas, 0 inválidas |
| `0x04/0x05` (49 B de carga) trae un **cuaternión (x,y,z,w)** en `carga[24..<40]` (4 × Float32 LE) | norma = 1,0; sigue el giro de los motores |
| Orientación → ángulos con descomposición **YXZ** (Y=yaw, X=pitch, Z=roll) sobre la rotación relativa a una referencia | yaw +21,89° para `yaw=100` 2 s; pitch −21,93° para `pitch=100` 2 s (**pitch = −θx**); roll ≈ 0 |
| Unidad de velocidad (SPEED) ≈ **0,11 °/s por unidad** a velocidades bajas (100 → ~22° en 2 s) | yaw 100: 21,8°; pitch 100: 21,9°; yaw 200: 37,9° (arranque con rampa); yaw 400: 75° |
| Signo: `+` aumenta yaw y pitch (según la convención de arriba); `−` los devuelve | vuelta a 0,3° con `−100` |
| El cabeceo tiene tope mecánico hacia arriba ≈ +28° desde el centro | `pitch=200` se queda en 28,5° |
| Telemetría de orientación a ~1,5 Hz (útil pero lenta) | ~167 tramas `0x04/0x05` en ~110 s |
| Con órdenes SPEED cada 0,25 s (time=10) la Osmo obedece | todas las fases de movimiento |

## Prueba de humo con la librería (GimbalKit, Swift, 2026-10-11)

`scripts/run-smoke.sh [--mover]`: conecta con `CoreBluetoothOMTransport` (recupera la Osmo ya conectada), lee con `OMDevice`.

| Medida | Resultado |
|---|---|
| Pose inicial (quieta, trípode) | (−0,011°, −0,003°, 0,002°) |
| Tras `speed(yaw: 10)` 2 s con órdenes cada 0,3 s | yaw **+22,01°**, pitch −0,18°, roll −1,04° |
| Tras `speed(yaw: −10)` 2 s | yaw **−0,013°** (vuelve al origen) |
| Batería | 18 %, `charging` pasa a `true` al enchufarla (bit de carga confirmado) |
| Autorización de Bluetooth | una app nueva necesita que se acepte el aviso del sistema la primera vez |

## Banco de pruebas GimbalLab con la Osmo (2026-10-11, `--auto-run`)

| Prueba | Resultado real |
|---|---|
| Conexión y telemetría viva | PASA: 1,0 Hz de actualización de pose |
| Reposo estable (5 s) | PASA: deriva 0,005–0,02° (una vez 6,3° justo tras un giro: la Osmo aún se asentaba) |
| Batería | PASA: 100 % con la carga completa |
| Yaw: `+10 °/s` 2 s y vuelta con `−10 °/s` | PASA: **+20,99° de ida, error de vuelta 0,146°** |

**Hallazgos de comportamiento (importantes para el diseño):**
- **Cada orden SPEED dura solo ~0,5 s.** Una sola orden de 10 °/s movió 4,95°; refrescada cada 0,3 s durante 2 s, ~21°. Todo movimiento
  continuo exige refrescar la orden (el deadman de 0,5 s del controlador ya lo exige).
- **La pose va retrasada (~1 Hz y con latencia):** leerla justo al parar mide un giro a medias (14,3° en vez de 21°). Hay que esperar
  ≥ 2 s de asentamiento tras `stop` antes de tomar una pose de referencia (así lo hace ya el navegador y ahora también el Lab).
- Tras la prueba de yaw la prueba de «parada» necesita el mismo asentamiento (corregido); pendiente de re-validar en hardware.
- Un binario con firma ad hoc que se reconstruye puede ser rechazado por macOS (`Taskgated Invalid Signature`) y perder el permiso de Bluetooth.

## Hipótesis / sin resolver

- `0x04/0x57` (el más frecuente, 6 B) **no cambia nunca** (ni con joystick ni con botones): el mando físico no sale por este
  canal. La Osmo se ve en macOS como «HID BLE»: probablemente joystick y botones llegan como informes HID (servicio 0x1812).
- Los 10 primeros bytes de la carga de `0x04/0x05` parecen ángulos de motor en 0,1° (Int16 LE): `carga[4..<6]` varía como el
  yaw (+217 para +21,7°) y `carga[0..<2]` como el pitch (−219, con desplazamiento cercano a ±180°). Sin confirmar.
- `0x05/0x06`: `carga[0]` = porcentaje de batería (bit de carga confirmado al enchufarla); sin contrastar el porcentaje con la pantalla.
- Con órdenes cada 0,1 s la Osmo no obedeció (o las descartó): usar ≥ 0,25 s entre órdenes de velocidad.
- Modos `RELATIVE`/`ABSOLUTE` de `OMRotate` sin probar en la SE.

## Incidente

Una prueba de velocidad `yaw=400` sobrepasó el freno de 45° (la telemetría llega a ~1,5 Hz) y la Osmo acabó 81° girada.
Un intento de regreso a ciegas empeoró (94°). Se arregló apagando y encendiendo la Osmo. **Lección:** nada de control en
bucle cerrado con esa telemetría sin limitar mucho la velocidad; el controlador debe tratar la pose como retardada.
