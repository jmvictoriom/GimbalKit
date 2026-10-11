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
        self.sender = sender; self.receiver = receiver; self.sequence = sequence
        self.commandType = commandType; self.commandSet = commandSet; self.command = command; self.payload = payload
    }
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

public struct DUMLParseResult: Sendable, Equatable {
    public let rawBytes: [UInt8]
    public let frame: DUMLFrame?
    public let crcValid: Bool
    public init(rawBytes: [UInt8], frame: DUMLFrame?, crcValid: Bool) {
        self.rawBytes = rawBytes; self.frame = frame; self.crcValid = crcValid
    }
    public var commandSet: UInt8? { frame?.commandSet ?? (rawBytes.count > 9 ? rawBytes[9] : nil) }
    public var command: UInt8? { frame?.command ?? (rawBytes.count > 10 ? rawBytes[10] : nil) }
}

public struct DUMLParser {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func feed(_ data: [UInt8]) -> [DUMLFrame] {
        feedEvents(data).compactMap(\.frame)
    }
    public mutating func feedEvents(_ data: [UInt8]) -> [DUMLParseResult] {
        buffer += data
        var results: [DUMLParseResult] = []
        while true {
            guard let start = buffer.firstIndex(of: 0x55) else { buffer.removeAll(); break }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 4 else { break }
            guard DUMLCRC.crc8(buffer[0..<3]) == buffer[3] else {
                results.append(DUMLParseResult(rawBytes: Array(buffer.prefix(4)), frame: nil, crcValid: false))
                buffer.removeFirst()
                continue
            }
            let total = Int(buffer[1]) | (Int(buffer[2] & 0x03) << 8)
            guard total >= 13 else {
                results.append(DUMLParseResult(rawBytes: Array(buffer.prefix(4)), frame: nil, crcValid: false))
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= total else { break }
            let raw = Array(buffer[0..<total])
            let expected = UInt16(raw[total - 2]) | (UInt16(raw[total - 1]) << 8)
            guard DUMLCRC.crc16(raw[0..<(total - 2)]) == expected else {
                results.append(DUMLParseResult(rawBytes: raw, frame: nil, crcValid: false))
                buffer.removeFirst(total)
                continue
            }
            let frame = DUMLFrame(sender: raw[4], receiver: raw[5],
                sequence: UInt16(raw[6]) | (UInt16(raw[7]) << 8), commandType: raw[8],
                commandSet: raw[9], command: raw[10], payload: Array(raw[11..<(total - 2)]))
            results.append(DUMLParseResult(rawBytes: raw, frame: frame, crcValid: true))
            buffer.removeFirst(total)
        }
        return results
    }
}
