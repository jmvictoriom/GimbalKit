import Testing
@testable import GimbalKitDJI

@Test func parserReportsValidAndBadCRCFramesWithoutChangingFeed() {
    var parser = DUMLParser()
    let bytes = realBytes(Real.yawA)
    let valid = parser.feedEvents(bytes)
    #expect(valid.count == 1)
    #expect(valid[0].crcValid)
    #expect(valid[0].frame?.commandSet == 0x04)
    #expect(valid[0].frame?.command == 0x05)
    #expect(parser.feed([]) == [])
    var damaged = realBytes(Real.yawA)
    damaged[damaged.count - 1] ^= 0x01
    let invalid = parser.feedEvents(damaged)
    #expect(invalid.count == 1)
    #expect(!invalid[0].crcValid)
    #expect(invalid[0].frame == nil)
    #expect(invalid[0].rawBytes == damaged)
    #expect(invalid[0].commandSet == 0x04)
    #expect(invalid[0].command == 0x05)
    var badHeader = realBytes(Real.yawA)
    badHeader[3] ^= 0x01
    let headerResult = parser.feedEvents(badHeader)
    #expect(headerResult.count == 1)
    #expect(!headerResult[0].crcValid)
    #expect(headerResult[0].rawBytes == Array(badHeader.prefix(4)))
    let recovered = parser.feedEvents(bytes)
    #expect(recovered.count == 1)
    #expect(recovered[0].crcValid)
    #expect(recovered[0].rawBytes == bytes)
}
