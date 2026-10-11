import GimbalKitDJI

func realBytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let s = hex.index(hex.startIndex, offsetBy: $0)
        return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)!
    }
}

func frame(_ hex: String) -> DUMLFrame {
    var parser = DUMLParser()
    return parser.feed(realBytes(hex))[0]
}

enum Real {
    // Giro de yaw con `yaw = 100` (2 s): de A a B ≈ +21,89° de yaw, +0,21° de pitch, +0,29° de roll.
    static let yawA = "553e044b04026e7c00040501f9fcff000084000300200132c503002c1800000c005403e36ab83eb4debbbea1fe193f98821cbf000000000100000000f6bc"
    static let yawB = "553e044b0402dfc300040501f9fcffd90084002cff2001a2dc0300ba2000000c0054032280f03e92f3f2be6a5c053f192408bf0000000000000000006780"
    // Giro de pitch con `pitch = 100` (2 s): de A a B ≈ −0,01° de yaw, +21,93° de pitch, −0,01° de roll.
    static let pitchA = "553e044b04025a1b000405fd060000020084000a002001b3181100ae440000f7ff4b033707353f83c034bfd535063d35f899bc0000000001000000003323"
    static let pitchB = "553e044b0402cb6200040522060000130084006a00200123301100ad44000003ffe802c09f323f29df2fbfc3802a3e668aed3d0000000001000000002bea"
    // Batería: carga[0] = 0x19 (25 %), último byte 0 (sin cargar).
    static let battery = "5535046827029e00400506190a1c00000000000000000000000000000e000e000000000000000000000000910b000000000000734a"
    // Telemetría constante (0x04/0x57): no se interpreta.
    static let constant = "5513040327021603400457000000000100e451"
}
