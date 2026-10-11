import Testing
@testable import GimbalKitDJI

@Test func decodesAttitudeQuaternionFromRealFrame() throws {
    let telemetry = try #require(OMTelemetry.decode(frame(Real.yawA)))
    guard case let .attitude(q) = telemetry else { Issue.record("no es attitude"); return }
    #expect(abs(q.x - (0.360190)) < 0.0001)
    #expect(abs(q.y - (-0.366933)) < 0.0001)
    #expect(abs(q.z - (0.601542)) < 0.0001)
    #expect(abs(q.w - (-0.611368)) < 0.0001)
    let norm = (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w).squareRoot()
    #expect(abs(norm - 1) < 1e-6)
}

@Test func decodesBatteryFromRealFrame() {
    #expect(OMTelemetry.decode(frame(Real.battery)) == .battery(percent: 25, charging: false))
}

@Test func ignoresUnknownMessages() {
    #expect(OMTelemetry.decode(frame(Real.constant)) == nil)
}

@Test func truncatedOrInvalidPayloadsDecodeToNil() {
    var f = frame(Real.yawA)
    f.payload = Array(f.payload.prefix(39))
    #expect(OMTelemetry.decode(f) == nil)
    f.payload = [UInt8](repeating: 0, count: 49)            // cuaternión de norma 0
    #expect(OMTelemetry.decode(f) == nil)
    f.payload = [UInt8](repeating: 0xFF, count: 49)         // floats NaN
    #expect(OMTelemetry.decode(f) == nil)
    var b = frame(Real.battery)
    b.payload = []
    #expect(OMTelemetry.decode(b) == nil)
    b.payload = [250, 0]                                    // porcentaje imposible
    #expect(OMTelemetry.decode(b) == nil)
}

@Test func quaternionAlgebra() throws {
    let s = (0.5).squareRoot()
    let q = try #require(Quaternion(x: 0, y: s, z: 0, w: s).normalized)
    let identity = q * q.conjugate
    #expect(abs(identity.w - 1) < 1e-9 && abs(identity.x) < 1e-9 && abs(identity.y) < 1e-9 && abs(identity.z) < 1e-9)
    #expect(Quaternion(x: 0, y: 0, z: 0, w: 0).normalized == nil)
    #expect(Quaternion(x: .nan, y: 0, z: 0, w: 1).normalized == nil)
}
