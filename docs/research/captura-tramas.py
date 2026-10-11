"""Captura tramas DUML crudas de la Osmo (sin mover nada) para vectores de prueba."""
import asyncio, sys
sys.path.insert(0, sys.argv[1])
from bleak import BleakScanner, BleakClient
from bleak.backends.device import BLEDevice
from CoreBluetooth import CBUUID
from gimbal import Gimbal, _crc16, _crc8

async def main():
    sc = BleakScanner(); await sc.start(); await asyncio.sleep(1); await sc.stop()
    mgr = sc._backend._manager
    peris = mgr.central_manager.retrieveConnectedPeripheralsWithServices_([CBUUID.UUIDWithString_("FFF0")])
    x = peris[0]
    dev = BLEDevice(str(x.identifier().UUIDString()), str(x.name()), (x, mgr))
    buf, seen, ok, bad = b"", {}, 0, 0
    async with BleakClient(dev, timeout=30) as c:
        def cb(_, d):
            nonlocal buf, ok, bad
            buf += bytes(d)
            while len(buf) >= 4:
                if buf[0] != 0x55: buf = buf[1:]; continue
                n = (buf[1] | buf[2] << 8) & 0x3FF
                if n < 13 or len(buf) < n: break
                f, buf = buf[:n], buf[n:]
                good = _crc8(f[:3]) == f[3] and _crc16(f[:-2], 0x3692) == int.from_bytes(f[-2:], "little")
                ok += good; bad += (not good)
                k = (f[9], f[10])
                if good and k not in seen: seen[k] = f.hex()
        await c.start_notify(Gimbal.FFF4, cb)
        await asyncio.sleep(8)
    print(f"tramas válidas={ok} inválidas={bad}")
    for k, v in sorted(seen.items()): print(f"0x{k[0]:02x}/0x{k[1]:02x} {v}")
asyncio.run(main())
