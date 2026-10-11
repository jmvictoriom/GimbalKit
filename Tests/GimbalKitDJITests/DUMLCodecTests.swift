import Testing
@testable import GimbalKitDJI

private func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let s = hex.index(hex.startIndex, offsetBy: $0)
        return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)!
    }
}

private let golden: [(OMRotate, String)] = [
    (OMRotate(yaw: 600, pitch: 0, roll: 0, time: 10, mode: .speed), "551504a90204010000040c580200000000800aa264"),
    (OMRotate(yaw: -600, pitch: 0, roll: 0, time: 10, mode: .speed), "551504a90204010000040ca8fd00000000800a9ca9"),
    (OMRotate(yaw: 0, pitch: 0, roll: 0, time: 10, mode: .speed), "551504a90204010000040c000000000000800a2c40"),
    (OMRotate(yaw: 900, pitch: -300, roll: 50, time: 20, mode: .relative), "551504a90204010000041484033200d4fe04144e7e"),
    (OMRotate(yaw: 1800, pitch: 0, roll: 0, time: 20, mode: .absolute), "551504a90204010000041408070000000005145d21"),
]

@Test func rotateFramesMatchReferenceVectors() {
    for (rotate, hex) in golden {
        #expect(rotate.frame().encoded() == bytes(hex), "vector \(hex)")
    }
}

@Test func crcMatchesReferenceHeaderAndSeed() {
    #expect(DUMLCRC.crc8(bytes("551504")[...]) == 0xa9)
    #expect(DUMLCRC.crc16(bytes("551504a9")[...]) == 0xdf0c)
}

@Test func parserDecodesGoldenFrame() {
    var parser = DUMLParser()
    let frames = parser.feed(bytes(golden[0].1))
    #expect(frames == [golden[0].0.frame()])
    #expect(frames[0].commandSet == 0x04)
    #expect(frames[0].command == 0x0c)
}

@Test func parserHandlesFramesSplitAcrossChunks() {
    var parser = DUMLParser()
    let all = bytes(golden[0].1) + bytes(golden[3].1)
    var out: [DUMLFrame] = []
    for chunk in stride(from: 0, to: all.count, by: 5).map({ Array(all[$0..<min($0 + 5, all.count)]) }) {
        out += parser.feed(chunk)
    }
    #expect(out == [golden[0].0.frame(), golden[3].0.frame()])
}

@Test func parserResyncsAfterGarbageAndDropsBadCRC() {
    var parser = DUMLParser()
    var corrupted = bytes(golden[1].1)
    corrupted[corrupted.count - 1] ^= 0xFF
    let input: [UInt8] = [0x00, 0x55, 0x01, 0xAA] + corrupted + bytes(golden[2].1)
    #expect(parser.feed(input) == [golden[2].0.frame()])
}

@Test func parserNeverReturnsFramesFromRandomBytes() {
    var parser = DUMLParser()
    var seed: UInt64 = 0x1234_5678
    var noise: [UInt8] = []
    for _ in 0..<10_000 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        noise.append(UInt8(truncatingIfNeeded: seed >> 33))
    }
    #expect(parser.feed(noise).isEmpty)
}

@Test func roundTripPreservesFields() {
    let frame = DUMLFrame(sender: 0x04, receiver: 0x02, sequence: 513, commandType: 0x40,
                          commandSet: 0x05, command: 0x06, payload: [1, 2, 3, 4, 5])
    var parser = DUMLParser()
    #expect(parser.feed(frame.encoded()) == [frame])
}
