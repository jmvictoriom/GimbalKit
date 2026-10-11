import Testing
import GimbalKit
@testable import GimbalKitDJI

actor FakeTransport: OMTransport {
    nonisolated let notifications: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private(set) var written: [[UInt8]] = []

    init() {
        (notifications, continuation) = AsyncStream.makeStream(of: [UInt8].self)
    }

    func write(_ bytes: [UInt8]) async throws { written.append(bytes) }

    nonisolated func push(_ bytes: [UInt8]) { continuation.yield(bytes) }
}

private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Test func declaresOnlyVerifiedCapabilities() {
    let device = OMDevice(transport: FakeTransport())
    #expect(device.capabilities == [.speedControl, .poseFeedback, .battery])
}

@Test func speedCommandBecomesRawSpeedFrame() async throws {
    let transport = FakeTransport()
    let device = OMDevice(transport: transport)
    try await device.send(.speed(yaw: 60, pitch: 0, roll: 0))
    #expect(await transport.written == [OMRotate(yaw: 600, pitch: 0, roll: 0, time: 10, mode: .speed).frame().encoded()])
    try await device.send(.speed(yaw: -10, pitch: 5, roll: 99))      // el roll no está soportado: se manda 0
    let expected = OMRotate(yaw: -100, pitch: 50, roll: 0, time: 10, mode: .speed).frame().encoded()
    #expect(await transport.written.last == expected)
}

@Test func stopSendsZeroSpeedFrame() async throws {
    let transport = FakeTransport()
    let device = OMDevice(transport: transport)
    try await device.send(.stop)
    #expect(await transport.written == [realBytes("551504a90204010000040c000000000000800a2c40")])
}

@Test func absoluteCommandsAreRejectedExplicitly() async {
    let device = OMDevice(transport: FakeTransport())
    await #expect(throws: OMDeviceError.unsupported("absolute")) {
        try await device.send(.absolute(Pose(yaw: 10, pitch: 0), seconds: 1))
    }
}

@Test func poseIsNilUntilFirstAttitudeThenTracksRealFrames() async throws {
    let transport = FakeTransport()
    let device = OMDevice(transport: transport)
    await device.start()
    #expect(await device.currentPose() == nil)
    for hex in [Real.yawA, Real.yawB] {
        let b = realBytes(hex)
        transport.push(Array(b[0..<20]))          // la trama llega partida en dos notificaciones
        transport.push(Array(b[20...]))
    }
    let tracked = await waitUntil { await device.currentPose().map { abs($0.yaw - 21.89) < 0.1 } ?? false }
    #expect(tracked)
    await device.zeroPose()
    #expect(await device.currentPose() == nil)
    await device.shutdown()
}

@Test func batteryIsReadFromTelemetry() async {
    let transport = FakeTransport()
    let device = OMDevice(transport: transport)
    await device.start()
    transport.push(realBytes(Real.battery))
    let got = await waitUntil { await device.battery?.percent == 25 }
    #expect(got)
    #expect(await device.battery?.charging == false)
    await device.shutdown()
}

@Test func garbageNotificationsNeverBreakTheDevice() async throws {
    let transport = FakeTransport()
    let device = OMDevice(transport: transport)
    await device.start()
    transport.push([0x55, 0xFF, 0x00, 0x13, 0x37])
    transport.push(realBytes(Real.constant))
    transport.push(realBytes(Real.yawA))
    let ok = await waitUntil { await device.currentPose() != nil }
    #expect(ok)
    await device.shutdown()
}
