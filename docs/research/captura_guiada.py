"""Captura guiada por voz: tramas DUML crudas etiquetadas por fase, para decodificar la telemetría."""
import asyncio, json, sys, time
sys.path.insert(0, sys.argv[1])
from bleak import BleakScanner, BleakClient
from bleak.backends.device import BLEDevice
from CoreBluetooth import CBUUID
from gimbal import Gimbal, _crc16, _crc8

FASES = [
    ("quieta", 6, "Sujeta la Osmo quieta, apuntando al frente. No la muevas."),
    ("yaw_derecha", 6, "Gira el mango despacio hacia la derecha, unos noventa grados."),
    ("yaw_centro", 6, "Vuelve despacio al centro."),
    ("yaw_izquierda", 6, "Gira el mango despacio hacia la izquierda, unos noventa grados."),
    ("yaw_centro2", 6, "Vuelve al centro y quédate quieto."),
    ("pitch_arriba", 6, "Inclina el mango despacio hacia arriba, unos cuarenta y cinco grados."),
    ("pitch_centro", 6, "Vuelve al centro."),
    ("pitch_abajo", 6, "Inclina el mango despacio hacia abajo, unos cuarenta y cinco grados."),
    ("pitch_centro2", 6, "Vuelve al centro y quédate quieto."),
    ("roll_derecha", 6, "Inclina el mango hacia la derecha, como si vertieras agua, unos treinta grados."),
    ("roll_centro", 6, "Vuelve al centro."),
    ("joystick_derecha", 5, "Empuja el joystick a la derecha y mantenlo."),
    ("joystick_izquierda", 5, "Ahora empuja el joystick a la izquierda y mantenlo."),
    ("joystick_arriba", 5, "Ahora hacia arriba y mantenlo."),
    ("joystick_abajo", 5, "Ahora hacia abajo y mantenlo."),
    ("joystick_suelto", 4, "Suelta el joystick."),
    ("boton_disparo", 5, "Pulsa una vez el botón de disparo."),
    ("boton_gatillo", 5, "Mantén pulsado el gatillo trasero."),
    ("gatillo_suelto", 4, "Suelta el gatillo."),
    ("fin", 2, "Captura terminada. Gracias."),
]

async def hablar(texto):
    p = await asyncio.create_subprocess_exec("say", "-v", "Mónica", texto)
    await p.wait()

async def main():
    sc = BleakScanner(); await sc.start(); await asyncio.sleep(1); await sc.stop()
    mgr = sc._backend._manager
    peris = mgr.central_manager.retrieveConnectedPeripheralsWithServices_([CBUUID.UUIDWithString_("FFF0")])
    if len(peris) == 0:
        print("SIN_OSMO: no hay ninguna Osmo conectada al sistema"); return
    x = peris[0]
    dev = BLEDevice(str(x.identifier().UUIDString()), str(x.name()), (x, mgr))
    out = open(sys.argv[2], "w")
    state = {"fase": "pre", "buf": b"", "ok": 0, "bad": 0}
    t0 = time.monotonic()
    async with BleakClient(dev, timeout=30) as c:
        def cb(_, d):
            b = state["buf"] + bytes(d)
            while len(b) >= 4:
                if b[0] != 0x55: b = b[1:]; continue
                n = (b[1] | b[2] << 8) & 0x3FF
                if n < 13 or len(b) < n: break
                f, b = b[:n], b[n:]
                good = _crc8(f[:3]) == f[3] and _crc16(f[:-2], 0x3692) == int.from_bytes(f[-2:], "little")
                state["ok" if good else "bad"] += 1
                out.write(json.dumps({"t": round(time.monotonic() - t0, 4), "fase": state["fase"], "crc": good, "hex": f.hex()}) + "\n")
            state["buf"] = b
        await c.start_notify(Gimbal.FFF4, cb)
        await hablar("Empezamos en tres, dos, uno.")
        for nombre, seg, frase in FASES:
            state["fase"] = nombre
            await hablar(frase)
            await asyncio.sleep(seg)
    out.close()
    print(f"CAPTURA_OK tramas_validas={state['ok']} invalidas={state['bad']}")

asyncio.run(main())
