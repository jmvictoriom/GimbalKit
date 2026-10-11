"""Mueve los motores con velocidades pequeñas y conocidas mientras registra la telemetría.
Freno automático: si la rotación respecto al inicio supera 45° (según el cuaternión de 0x04/0x05), para todo."""
import asyncio, json, math, struct, sys, time
sys.path.insert(0, sys.argv[1])
from bleak import BleakScanner, BleakClient
from bleak.backends.device import BLEDevice
from CoreBluetooth import CBUUID
from gimbal import Gimbal, _crc16, _crc8

ABORT_DEG = 45.0
def quat(f):
    if f[9] == 0x04 and f[10] == 0x05 and len(f) >= 11 + 40:
        q = struct.unpack("<4f", bytes(f[11 + 24:11 + 40]))
        n = math.sqrt(sum(v * v for v in q))
        return tuple(v / n for v in q) if 0.9 < n < 1.1 else None

async def main():
    sc = BleakScanner(); await sc.start(); await asyncio.sleep(1); await sc.stop()
    mgr = sc._backend._manager
    peris = mgr.central_manager.retrieveConnectedPeripheralsWithServices_([CBUUID.UUIDWithString_("FFF0")])
    if len(peris) == 0: print("SIN_OSMO"); return
    x = peris[0]
    dev = BLEDevice(str(x.identifier().UUIDString()), str(x.name()), (x, mgr))
    out = open(sys.argv[2], "w"); t0 = time.monotonic()
    st = {"fase": "pre", "buf": b"", "q0": None, "abort": False, "maxdeg": 0.0}
    async with BleakClient(dev, timeout=30) as c:
        g = Gimbal.__new__(Gimbal); g._ble_client = c
        def log(kind, **kw):
            out.write(json.dumps({"t": round(time.monotonic() - t0, 4), "fase": st["fase"], "k": kind, **kw}) + "\n")
        def cb(_, d):
            b = st["buf"] + bytes(d)
            while len(b) >= 4:
                if b[0] != 0x55: b = b[1:]; continue
                n = (b[1] | b[2] << 8) & 0x3FF
                if n < 13 or len(b) < n: break
                f, b = b[:n], b[n:]
                if not (_crc8(f[:3]) == f[3] and _crc16(f[:-2], 0x3692) == int.from_bytes(f[-2:], "little")): continue
                log("rx", hex=f.hex())
                q = quat(f)
                if q:
                    if st["q0"] is None: st["q0"] = q
                    dot = abs(sum(a * b2 for a, b2 in zip(st["q0"], q)))
                    deg = math.degrees(2 * math.acos(min(1.0, dot)))
                    st["maxdeg"] = max(st["maxdeg"], deg)
                    if deg > ABORT_DEG: st["abort"] = True
            st["buf"] = b
        await c.start_notify(Gimbal.FFF4, cb)
        async def stop():
            for _ in range(3):
                await g.rotate(yaw=0, pitch=0, roll=0, time=10, mode=Gimbal.RotationMode.SPEED)
                await asyncio.sleep(0.1)
            log("tx", yaw=0, pitch=0, roll=0)
        async def mover(yaw, pitch, seg):
            end = time.monotonic() + seg
            while time.monotonic() < end and not st["abort"]:
                await g.rotate(yaw=yaw, pitch=pitch, roll=0, time=10, mode=Gimbal.RotationMode.SPEED)
                log("tx", yaw=yaw, pitch=pitch, roll=0)
                await asyncio.sleep(0.25)
        try:
            st["fase"] = "quieta"; await asyncio.sleep(3)
            for eje in ("yaw", "pitch"):
                for raw in (100, 200, 400):
                    for signo in (1, -1):
                        if st["abort"]: break
                        v = signo * raw
                        st["fase"] = f"{eje}_{v}"
                        await mover(v if eje == "yaw" else 0, v if eje == "pitch" else 0, 2.0)
                        await stop(); st["fase"] = f"{eje}_{v}_parada"; await asyncio.sleep(1.5)
        finally:
            await stop()
            await asyncio.sleep(0.5)
    out.close()
    print(f"FIN abortado={st['abort']} max_rotacion_deg={st['maxdeg']:.1f}")

asyncio.run(main())
