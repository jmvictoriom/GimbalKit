"""Experimento desechable: ¿la Osmo Mobile SE habla el protocolo de om-research?

Uso: python -I probe.py <ruta-om-research> [--mover]
1. Escanea BLE y lista candidatos (servicio FFF0 o nombre con OM/Osmo).
2. Conecta al primero, vuelca servicios y características.
3. Escucha FFF4 unos segundos y decodifica DUML.
4. Con --mover: giro suave de ida y vuelta en yaw (modo SPEED, el probado en OM4).
"""
import asyncio
import sys
from collections import Counter

sys.path.insert(0, sys.argv[1])  # código de om-research, revisado antes
from bleak import BleakScanner, BleakClient  # noqa: E402
from duml import DUMLParser  # noqa: E402
from gimbal import Gimbal  # noqa: E402

FFF0 = Gimbal.FFF0.lower()


async def main():
    mover = "--mover" in sys.argv
    # Ya conectada al sistema (HID): recuperarla sin escanear
    from bleak.backends.device import BLEDevice
    from CoreBluetooth import CBUUID
    sc = BleakScanner()
    await sc.start(); await asyncio.sleep(1); await sc.stop()
    mgr = sc._backend._manager
    peris = mgr.central_manager.retrieveConnectedPeripheralsWithServices_([CBUUID.UUIDWithString_("FFF0")])
    print(f"Conectados al sistema con FFF0: {[str(x.name()) for x in peris]}")
    if peris:
        x = peris[0]
        cands = [(BLEDevice(str(x.identifier().UUIDString()), str(x.name()), (x, mgr)), None, str(x.name()))]
        await use(cands[0][0], mover)
        return
    print("Escaneando 10 s…")
    found = await BleakScanner.discover(timeout=10, return_adv=True)
    cands = []
    for dev, adv in found.values():
        name = adv.local_name or dev.name or ""
        uuids = [u.lower() for u in adv.service_uuids]
        if FFF0 in uuids or any(k in name.lower() for k in ("om ", "osmo", "om_", "omse", "dji")) or name.upper().startswith("OM"):
            cands.append((dev, adv, name))
            print(f"  CANDIDATO {name!r} id={dev.address} rssi={adv.rssi} uuids={uuids} mfr={ {k: v.hex() for k, v in adv.manufacturer_data.items()} }")
    print(f"Dispositivos BLE vistos: {len(found)}; candidatos: {len(cands)}")
    if not cands:
        for dev, adv in found.values():
            name = adv.local_name or dev.name
            mfr = {f"0x{k:04x}": v.hex() for k, v in adv.manufacturer_data.items()}
            print(f"  · {name!r} {dev.address} rssi={adv.rssi} uuids={adv.service_uuids} mfr={mfr}")
            if 0x08AA in adv.manufacturer_data:
                cands.append((dev, adv, name)); continue
            if name:
                continue
            try:
                async with BleakClient(dev, timeout=6) as c:
                    if any(s.uuid.lower() == FFF0 for s in c.services):
                        print("    -> expone FFF0"); cands.append((dev, adv, name))
            except Exception as e:
                print(f"    (no conecta: {type(e).__name__})")
        if not cands:
            return

    await use(cands[0][0], mover)


async def use(dev, mover):
    async with BleakClient(dev, timeout=30) as client:
        print(f"\nConectado a {dev.address} · MTU {client.mtu_size}")
        for s in client.services:
            print(f"Servicio {s.uuid} ({s.description})")
            for c in s.characteristics:
                print(f"   car. {c.uuid} {c.properties}")

        if not any(s.uuid.lower() == FFF0 for s in client.services):
            print("\nNO expone FFF0: el protocolo de om-research no aplica tal cual.")
            return

        parser, stats = DUMLParser(), Counter()

        def on_notify(_, data: bytearray):
            for p in parser.feed(bytes(data)):
                key = (p.cmd_set, p.cmd)
                stats[key] += 1
                if stats[key] <= 2:
                    print(f"   DUML {p}")

        await client.start_notify(Gimbal.FFF4, on_notify)
        print("\nEscuchando FFF4 6 s…")
        await asyncio.sleep(6)

        if mover:
            g = Gimbal.__new__(Gimbal)  # reutiliza rotate() con nuestro cliente
            g._ble_client = client
            print("\nGiro suave: derecha, izquierda, parar")
            for yaw in (600, -600, 0):
                await g.rotate(yaw=yaw, pitch=0, roll=0, time=10, mode=Gimbal.RotationMode.SPEED)
                await asyncio.sleep(1.5)
            await asyncio.sleep(2)

        await client.stop_notify(Gimbal.FFF4)
        print("\nResumen de mensajes (cmd_set, cmd): veces")
        for (cs, c), n in sorted(stats.items()):
            print(f"   0x{cs:02x} 0x{c:02x}: {n}")


asyncio.run(main())
