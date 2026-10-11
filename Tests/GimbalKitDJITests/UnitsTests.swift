import Testing
@testable import GimbalKitDJI

@Test func convertsDegreesPerSecondToRawUnits() {
    #expect(OMUnits.raw(forDegreesPerSecond: 10) == 100)
    #expect(OMUnits.raw(forDegreesPerSecond: -5.04) == -50)
    #expect(OMUnits.raw(forDegreesPerSecond: 0) == 0)
    #expect(OMUnits.degreesPerSecond(forRaw: 250) == 25)
}

@Test func clampsAndNeutralizesBadValues() {
    #expect(OMUnits.raw(forDegreesPerSecond: 1_000_000) == OMUnits.maxRaw)
    #expect(OMUnits.raw(forDegreesPerSecond: -1_000_000) == -OMUnits.maxRaw)
    #expect(OMUnits.raw(forDegreesPerSecond: .nan) == 0)
    #expect(OMUnits.raw(forDegreesPerSecond: .infinity) == 0)
}
