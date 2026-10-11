import Foundation
import Testing
import GimbalKit
@testable import GimbalKitDJI

@Test func identicalAttitudesHaveNewMarksButCacheReadsDoNot() async throws {
    let device = OMDevice(transport: FakeTransport(), now: { Date(timeIntervalSince1970: 10) })
    #expect(await device.poseSample() == nil)
    await device.ingest(realBytes(Real.yawA))
    let a = try #require(await device.poseSample())
    #expect(await device.poseSample() == a)
    await device.ingest(realBytes(Real.yawA))
    let b = try #require(await device.poseSample())
    #expect(a.pose == b.pose)
    #expect(b.sequence == a.sequence + 1)
    #expect(b.receivedAt == Date(timeIntervalSince1970: 10))
    await device.ingest(realBytes(Real.battery))
    #expect(await device.poseSample() == b)
    await device.zeroPose()
    #expect(await device.poseSample() == nil)
    await device.ingest(realBytes(Real.yawA))
    await device.shutdown()
    #expect(await device.currentPose() == nil)
}
