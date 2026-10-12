import Foundation
import Testing
import GimbalKit
import GimbalKitDJI
@testable import GimbalHostSupport

@Suite struct MotionStopCounterAndRuntimeStopTokenTests {
@Test func stopCounterIsSynchronousAndThreadSafe() async {
    let counter = MotionStopCounter()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                for _ in 0..<1_000 { counter.increment() }
            }
        }
    }
    #expect(counter.read() == 8_000)
}

@Test func oldStopTokenAbortsBeforeConnectingOrMoving() async throws {
    let counter = MotionStopCounter()
    let factory = LinkFactory([FakeLink()])
    let runtime = HostRuntime(
        makeLink: { factory.next() },
        store: ZoneStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        motionStopCounter: counter
    )
    let oldToken = counter.read()
    await runtime.humanStop()
    #expect(counter.read() == oldToken + 1)
    await #expect(throws: NavigationError.interrupted) {
        try await runtime.look(zone: "mesa", leaseSeconds: 30, stopToken: oldToken)
    }
    #expect(counter.read() == oldToken + 1)
    #expect(factory.attempts == 0)
}

@Test func stopAndHumanStopIncrementEvenWithoutARig() async throws {
    let counter = MotionStopCounter()
    let factory = LinkFactory([FakeLink()])
    let runtime = HostRuntime(
        makeLink: { factory.next() },
        store: ZoneStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        motionStopCounter: counter
    )
    try await runtime.stop()
    #expect(counter.read() == 1)
    await runtime.humanStop()
    #expect(counter.read() == 2)
    #expect(factory.attempts == 0)
}

@Test func currentTokenReachesTheExistingReferenceGuard() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = FakeLink()
    let sleeper = StepSleeper()
    let clock = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let counter = MotionStopCounter()
    let runtime = HostRuntime(
        makeLink: { link },
        store: ZoneStore(url: root.appendingPathComponent("zones.json")),
        clock: clock,
        motionStopCounter: counter
    )
    try await runtime.start()
    #expect(await eventually { (try? await runtime.status().connected) == true })
    await link.attitude()
    #expect(await eventually { (try? await runtime.status().pose) != nil })
    let token = counter.read()
    await #expect(throws: NavigationError.referenceRequired) {
        try await runtime.look(zone: "mesa", leaseSeconds: 30, stopToken: token)
    }
    await runtime.shutdown()
}

private final class CounterReadStopProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var counter: MotionStopCounter?
    private var readsUntilStop: Int?

    func attach(_ counter: MotionStopCounter) { lock.withLock { self.counter = counter } }
    func arm(afterReads count: Int) { lock.withLock { readsUntilStop = count } }

    func didRead() {
        let target = lock.withLock { () -> MotionStopCounter? in
            guard let readsUntilStop else { return nil }
            if readsUntilStop == 1 {
                self.readsUntilStop = nil
                return counter
            }
            self.readsUntilStop = readsUntilStop - 1
            return nil
        }
        target?.increment()
    }
}

private final class CounterReadSignalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var readsUntilSignal: Int?

    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }
    func arm(afterReads count: Int) { lock.withLock { readsUntilSignal = count } }

    func didRead() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard let readsUntilSignal else { return false }
            if readsUntilSignal == 1 {
                self.readsUntilSignal = nil
                return true
            }
            self.readsUntilSignal = readsUntilSignal - 1
            return false
        }
        if shouldSignal { continuation.yield(()) }
    }

    func waitUntilSignalled() async {
        for await _ in stream { break }
    }
}

private func containsNonzeroSpeedFrame(_ frames: [[UInt8]]) -> Bool {
    frames.contains { frame in
        guard frame.count >= 19, frame[10] == 0x0C else { return false }
        return frame[11...16].contains { $0 != 0 }
    }
}

@Test func stopCounterChangingAfterRequestLeaseReleasesTheNewLease() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = FakeLink()
    let sleeper = StepSleeper()
    let clock = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let probe = CounterReadStopProbe()
    let counter = MotionStopCounter(onRead: { probe.didRead() })
    probe.attach(counter)
    let runtime = HostRuntime(makeLink: { link }, store: ZoneStore(url: root.appendingPathComponent("zones.json")),
                              clock: clock, motionStopCounter: counter)
    try await runtime.start()
    #expect(await eventually { (try? await runtime.status().connected) == true })
    await link.attitude()
    #expect(await eventually { (try? await runtime.status().pose) != nil })
    let draft = try await runtime.prepareZone(name: "mesa")
    try await runtime.confirmZone(draft)
    let token = counter.read()

    probe.arm(afterReads: 3)
    await #expect(throws: NavigationError.interrupted) {
        try await runtime.look(zone: "mesa", leaseSeconds: 30, stopToken: token)
    }
    #expect(counter.read() == token + 1)
    #expect(try await runtime.status().lease == nil)
    #expect(!containsNonzeroSpeedFrame(await link.writes))
    await runtime.shutdown()
}

// The control run proves the same off-center samples would produce SPEED.
@Test(arguments: [false, true])
func stopAfterLeaseGrantRevokesBeforeTheNextSpeedPulse(stop: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = VariableAttitudeHostLink()
    let sleeper = StepSleeper()
    let clock = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let probe = CounterReadSignalProbe()
    let counter = MotionStopCounter(onRead: { probe.didRead() })
    let runtime = HostRuntime(makeLink: { link }, store: ZoneStore(url: root.appendingPathComponent("zones.json")),
                              clock: clock, motionStopCounter: counter)
    try await runtime.start()
    #expect(await eventually { (try? await runtime.status().connected) == true })
    await link.attitude(yaw: 0)
    #expect(await eventually { (try? await runtime.status().pose) != nil })
    let draft = try await runtime.prepareZone(name: "mesa")
    try await runtime.confirmZone(draft)
    await link.attitude(yaw: 5)
    #expect(await eventually { abs(((try? await runtime.status().pose?.yaw) ?? 0) - 5) < 0.001 })
    let pose = try #require(try await runtime.status().pose)
    #expect(abs(pose.yaw) > NavigationLimits().deadband)
    #expect(draft.zone.contains(pose))
    let token = counter.read()
    probe.arm(afterReads: 3)
    let look = Task { try await runtime.look(zone: "mesa", leaseSeconds: 30, stopToken: token) }
    await probe.waitUntilSignalled()
    #expect(try await runtime.status().lease != nil)
    // Wait for the navigator's initial halt and settling wait, after its guard.
    #expect(await eventually { await link.writes.count >= 2 })
    #expect(await eventually { await sleeper.requested.filter { $0 == 0.1 }.count >= 2 })
    if stop { await runtime.humanStop() }
    let writesAfterStop = await link.writes.count
    // Fresh, distinct samples away from the center satisfy the settling requirements. El navegador necesita ~10 pasos simulados
    // (0,9 s de asentamiento en pasos de 0,1 s); el margen amplio evita fallos intermitentes bajo la carga de la suite completa.
    for _ in 0..<40 {
        let waits = await sleeper.requested.filter { $0 == 0.1 }.count
        await sleeper.advance(0.1)
        await link.attitude(yaw: 5)
        if !stop {
            #expect(await eventually {
                let speed = containsNonzeroSpeedFrame(await link.writes)
                let waiting = await sleeper.requested.filter { $0 == 0.1 }.count > waits
                return speed || waiting
            })
            if containsNonzeroSpeedFrame(await link.writes) { break }
        }
    }
    if stop {
        await #expect(throws: SafetyViolation.leaseExpired) { try await look.value }
        #expect(!containsNonzeroSpeedFrame(Array(await link.writes.dropFirst(writesAfterStop))))
        #expect(try await runtime.status().lease == nil)
    } else {
        #expect(containsNonzeroSpeedFrame(await link.writes))
        await runtime.humanStop()
        await sleeper.advance(0.1)
        _ = await look.result
    }
    await runtime.shutdown()
}

@Test func nilTokenKeepsTheExistingDisconnectedLookError() async throws {
    let runtime = HostRuntime(
        makeLink: { FakeLink() },
        store: ZoneStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )
    await #expect(throws: SafetyViolation.poseUnavailable) {
        try await runtime.look(zone: "mesa", leaseSeconds: 30)
    }
}

}

/// Synthetic attitude telemetry; no changes to the existing FakeLink fixture.
actor VariableAttitudeHostLink: HostLink {
    nonisolated let notifications: AsyncStream<[UInt8]>
    nonisolated let disconnects: AsyncStream<Void>
    private let bytes: AsyncStream<[UInt8]>.Continuation
    private let disconnected: AsyncStream<Void>.Continuation
    private(set) var writes: [[UInt8]] = []
    init() {
        (notifications, bytes) = AsyncStream.makeStream(of: [UInt8].self)
        (disconnects, disconnected) = AsyncStream.makeStream(of: Void.self)
    }
    func connect() {}
    func disconnect() { bytes.finish(); disconnected.finish() }
    func drop() { disconnected.yield(()) }
    func write(_ data: [UInt8]) { writes.append(data) }
    func attitude(yaw: Double) {
        let radians = yaw * .pi / 180 / 2
        var payload = [UInt8](repeating: 0, count: 24)
        for value in [Float(0), 0, Float(sin(radians)), Float(cos(radians))] {
            let raw = value.bitPattern
            payload += (0..<4).map { UInt8(truncatingIfNeeded: raw >> ($0 * 8)) }
        }
        // YXZ yaw is rotation around Y.
        payload.swapAt(28, 32); payload.swapAt(29, 33)
        payload.swapAt(30, 34); payload.swapAt(31, 35)
        bytes.yield(DUMLFrame(sender: 4, receiver: 2, sequence: 0, commandType: 0,
                            commandSet: 4, command: 5, payload: payload).encoded())
    }
}
