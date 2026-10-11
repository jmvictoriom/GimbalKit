/// CRC de DUML. CRC8 (reflejado, poli 0x31 → 0x8C, semilla 0x77) sobre los 3 primeros bytes;
/// CRC16 (reflejado, poli 0x1021 → 0x8408, semilla 0x3692) sobre toda la trama anterior a la propia CRC.
enum DUMLCRC {
    static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var crc: UInt8 = 0x77
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1 }
        }
        return crc
    }

    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0x3692
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        }
        return crc
    }
}
