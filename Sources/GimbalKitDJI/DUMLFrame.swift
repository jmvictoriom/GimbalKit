public struct DUMLFrame: Sendable, Equatable {
    public var sender: UInt8
    public var receiver: UInt8
    public var sequence: UInt16
    public var commandType: UInt8
    public var commandSet: UInt8
    public var command: UInt8
    public var payload: [UInt8]

    public init(sender: UInt8, receiver: UInt8, sequence: UInt16, commandType: UInt8,
                commandSet: UInt8, command: UInt8, payload: [UInt8]) {
        self.sender = sender
        self.receiver = receiver
        self.sequence = sequence
        self.commandType = commandType
        self.commandSet = commandSet
        self.command = command
        self.payload = payload
    }

    /// 0x55, longitud (10 bits) + versión, CRC8, 7 bytes de cabecera, carga, CRC16 (LE).
    public func encoded() -> [UInt8] {
        let total = 11 + payload.count + 2
        var out: [UInt8] = [0x55, UInt8(total & 0xFF), UInt8((total >> 8) & 0x03) | 0x04]
        out.append(DUMLCRC.crc8(out[0..<3]))
        out += [sender, receiver, UInt8(sequence & 0xFF), UInt8(sequence >> 8), commandType, commandSet, command]
        out += payload
        let crc = DUMLCRC.crc16(out[0...])
        out += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return out
    }
}

public struct DUMLParser {
    private var buffer: [UInt8] = []

    public init() {}

    /// Acumula bytes y devuelve las tramas completas con CRC válido. Descarta basura y tramas corruptas.
    public mutating func feed(_ data: [UInt8]) -> [DUMLFrame] {
        buffer += data
        var frames: [DUMLFrame] = []
        while true {
            guard let start = buffer.firstIndex(of: 0x55) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 4 else { break }
            let total = Int(buffer[1]) | (Int(buffer[2] & 0x03) << 8)
            guard total >= 13, buffer[3] == DUMLCRC.crc8(buffer[0..<3]) else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= total else { break }
            let raw = Array(buffer[0..<total])
            let expected = UInt16(raw[total - 2]) | (UInt16(raw[total - 1]) << 8)
            guard DUMLCRC.crc16(raw[0..<(total - 2)]) == expected else {
                buffer.removeFirst()
                continue
            }
            frames.append(DUMLFrame(
                sender: raw[4], receiver: raw[5],
                sequence: UInt16(raw[6]) | (UInt16(raw[7]) << 8),
                commandType: raw[8], commandSet: raw[9], command: raw[10],
                payload: Array(raw[11..<(total - 2)])
            ))
            buffer.removeFirst(total)
        }
        return frames
    }
}
