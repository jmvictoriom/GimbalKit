import Foundation
import Testing
import GimbalKit
@testable import GimbalHostSupport

@Suite struct ZoneMapProjectionTests {
    @Test func referenceAndCorners() throws {
        let reference = try #require(ZoneMapProjection.point(for: Pose()))
        #expect(reference.x == 0.5 && reference.y == 0.5)
        let topLeft = try #require(ZoneMapProjection.point(yaw: -90, pitch: 45))
        let bottomRight = try #require(ZoneMapProjection.point(yaw: 90, pitch: -45))
        #expect(topLeft.x == 0 && topLeft.y == 0)
        #expect(bottomRight.x == 1 && bottomRight.y == 1)
    }

    @Test func outOfRangeClipsToEdges() throws {
        let point = try #require(ZoneMapProjection.point(for: Pose(yaw: 200, pitch: -100)))
        #expect(point.x == 1 && point.y == 1)
        let opposite = try #require(ZoneMapProjection.point(yaw: -200, pitch: 100))
        #expect(opposite.x == 0 && opposite.y == 0)
        let rect = try #require(ZoneMapProjection.rect(for: ZoneRecord(Zone(name: "todo", yaw: -180...180, pitch: -90...90))))
        #expect(rect.origin.x == 0 && rect.origin.y == 0)
        #expect(rect.width == 1 && rect.height == 1)
        let outside = try #require(ZoneMapProjection.rect(for: ZoneRecord(Zone(name: "fuera", yaw: 100...120, pitch: 50...60))))
        #expect(outside.origin.x == 1 && outside.origin.y == 0)
        #expect(outside.width == 0 && outside.height == 0)
    }

    @Test func zoneBoundsProjectWithPitchInverted() throws {
        let zone = ZoneRecord(Zone(name: "mesa", yaw: -45...45, pitch: -22.5...22.5))
        let rect = try #require(ZoneMapProjection.rect(for: zone))
        #expect(rect.origin.x == 0.25 && rect.origin.y == 0.25)
        #expect(rect.width == 0.5 && rect.height == 0.5)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonfiniteValuesAreIgnored(value: Double) {
        #expect(ZoneMapProjection.point(yaw: value, pitch: 0) == nil)
        #expect(ZoneMapProjection.point(yaw: 0, pitch: value) == nil)
        #expect(ZoneMapProjection.point(for: Pose(roll: value)) == nil)
    }

    @Test func missingPoseAndInfiniteZoneAreIgnored() {
        #expect(ZoneMapProjection.point(for: nil) == nil)
        let yaw = ZoneRecord(Zone(name: "inválida", yaw: 0...Double.infinity, pitch: -10...10))
        let pitch = ZoneRecord(Zone(name: "inválida", yaw: -10...10, pitch: -Double.infinity...10))
        #expect(ZoneMapProjection.rect(for: yaw) == nil)
        #expect(ZoneMapProjection.rect(for: pitch) == nil)
    }
    @Test(arguments: ["yawLower", "yawUpper", "pitchLower", "pitchUpper"])
    func nanZoneBoundsAreIgnored(field: String) throws {
        var fields: [String: Any] = ["name": "inválida", "yawLower": -10, "yawUpper": 10,
                                   "pitchLower": -10, "pitchUpper": 10, "forbidden": false]
        fields[field] = "NaN"
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let zone = try decoder.decode(ZoneRecord.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(ZoneMapProjection.rect(for: zone) == nil)
    }

}
