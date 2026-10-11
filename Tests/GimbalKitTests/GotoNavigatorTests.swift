import Foundation
import Testing
import GimbalKit
import GimbalKitSim

func navigationFixture(frozen: Bool = false, timeout: Bool = false) async throws
    -> (GotoNavigator, GimbalController, LaggedPoseDevice, Lease) {
    let clock = ManualClock()
    let dev = LaggedPoseDevice(clock: clock, pose: Pose(yaw: -8, pitch: -6))
    await dev.setFrozen(frozen)
    await dev.setImmobile(timeout)
    let zone = Zone(name: "mesa", yaw: -12...12, pitch: -12...12)
    let c = GimbalController(device: dev, policy: makePolicy(zones: [zone]), now: { clock.now() })
    let deadlines = NavigationDeadlineSleeper(clock: clock)
    let timing = RuntimeClock(now: { clock.now() }, sleep: { seconds in
        if seconds > 0.3 { try await deadlines.sleep(seconds); return }
        try Task.checkCancellation()
        await dev.advance(seconds)
        await c.tick()
        await deadlines.timeAdvanced()
        await Task.yield()
    })
    let lease = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 30)
    return (GotoNavigator(controller: c, clock: timing), c, dev, lease)
}

@Test func gotoWithLagStaysInsideZoneAndUsesOnlySpacedSpeedAndStop() async throws {
    let (nav, c, dev, lease) = try await navigationFixture()
    let pose = try await nav.go(to: "mesa", source: lease.source, lease: lease)
    #expect(abs(pose.yaw) <= 2 && abs(pose.pitch) <= 2)
    #expect(await dev.truePoses.allSatisfy { (-12.0...12).contains($0.yaw) && (-12.0...12).contains($0.pitch) })
    let sent = await dev.sent
    let speeds = sent.compactMap { date, command -> Date? in
        if case let .speed(y, p, r) = command {
            #expect(max(abs(y), abs(p)) <= 6 && r == 0)
            return date
        }
        #expect(command == .stop)
        return nil
    }
    for i in speeds.indices.dropFirst() { #expect(speeds[i].timeIntervalSince(speeds[i - 1]) >= 0.25) }
    #expect(sent.last?.1 == .stop)
    #expect(await c.activeLease?.id == lease.id)
}

@Test func frozenPoseAndUnreachableTargetStopWithTypedErrors() async throws {
    for frozen in [true, false] {
        let (nav, c, dev, lease) = try await navigationFixture(frozen: frozen, timeout: !frozen)
        await #expect(throws: frozen ? NavigationError.stalePose : NavigationError.timeout) {
            try await nav.go(to: "mesa", source: lease.source, lease: lease)
        }
        #expect(await dev.sent.last?.1 == .stop)
        #expect(await c.activeLease == nil)
    }
}

actor CancelGate {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private(set) var waiting = false
    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }
    func sleep() async throws {
        waiting = true
        for await _ in stream { break }
        try Task.checkCancellation()
    }
}

@Test func cancelledGotoStopsAndReleasesItsLease() async throws {
    let clock = ManualClock()
    let dev = LaggedPoseDevice(clock: clock)
    let c = GimbalController(device: dev, policy: makePolicy(), now: { clock.now() })
    let gate = CancelGate()
    let deadlines = NavigationDeadlineSleeper(clock: clock)
    let nav = GotoNavigator(controller: c, clock: RuntimeClock(now: { clock.now() }, sleep: { seconds in
        if seconds > 0.3 { try await deadlines.sleep(seconds) }
        else { try await gate.sleep() }
    }))
    let lease = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 30)
    let task = Task { try await nav.go(to: "mesa", source: lease.source, lease: lease) }
    while !(await gate.waiting) { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await dev.sent.last?.1 == .stop)
    #expect(await c.activeLease == nil)
}

actor PulseCancelGate {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private(set) var waiting = false
    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }
    func holdPulse() async throws {
        waiting = true
        for await _ in stream { break }
        try Task.checkCancellation()
    }
}
@Test func cancellationDuringSpeedPulseLeavesStopAsLastCommand() async throws {
    let clock = ManualClock()
    let dev = LaggedPoseDevice(clock: clock, pose: Pose(yaw: -8))
    let zone = Zone(name: "mesa", yaw: -12...12, pitch: -12...12)
    let c = GimbalController(device: dev, policy: makePolicy(zones: [zone]), now: { clock.now() })
    let gate = PulseCancelGate()
    let deadlines = NavigationDeadlineSleeper(clock: clock)
    let timing = RuntimeClock(now: { clock.now() }, sleep: { seconds in
        if seconds > 0.3 { try await deadlines.sleep(seconds); return }
        if seconds >= 0.3 { try await gate.holdPulse() }
        else { await dev.advance(seconds); await c.tick(); try Task.checkCancellation() }
    })
    let nav = GotoNavigator(controller: c, clock: timing)
    let lease = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 30)
    let task = Task { try await nav.go(to: "mesa", source: lease.source, lease: lease) }
    while !(await gate.waiting) { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    await dev.advance(0.2)
    #expect(await dev.sent.last?.1 == .stop)
    #expect(await dev.truePoses.allSatisfy { zone.contains($0) })
    #expect(await c.activeLease == nil)
}

extension GatedPoseDevice: PoseFeedbackDevice {
    func poseSample() async -> PoseSample? {
        guard let pose = await currentPose() else { return nil }
        return PoseSample(pose: pose, receivedAt: Date(timeIntervalSince1970: 1_000_000), sequence: 1)
    }
}
@Test func cancellationStopsEvenWhenFeedbackReadIsSuspended() async throws {
    let clock = ManualClock()
    let dev = GatedPoseDevice()
    let c = GimbalController(device: dev, policy: makePolicy(), now: { clock.now() })
    let deadlines = NavigationDeadlineSleeper(clock: clock)
    let nav = GotoNavigator(controller: c, clock: RuntimeClock(now: { clock.now() }, sleep: { seconds in
        if seconds > 0.3 { try await deadlines.sleep(seconds) }
        else { try Task.checkCancellation() }
    }))
    let lease = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 30)
    let task = Task { try await nav.go(to: "mesa", source: lease.source, lease: lease) }
    while !(await dev.isWaiting) { await Task.yield() }
    task.cancel()
    while await dev.commands.last != .stop { await Task.yield() }
    #expect(await c.activeLease == nil)
    await #expect(throws: CancellationError.self) { try await task.value }
    await dev.open()
    #expect(await dev.commands == [.stop])
}

/// Long sleeps observe manual time; they never advance the simulation themselves.
actor NavigationDeadlineSleeper {
    let clock: ManualClock
    private var waiters: [UUID: (Date, AsyncStream<Void>.Continuation)] = [:]
    init(clock: ManualClock) { self.clock = clock }
    var isWaiting: Bool { !waiters.isEmpty }
    func sleep(_ seconds: Double) async throws {
        let deadline = clock.now().addingTimeInterval(seconds)
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        waiters[id] = (deadline, continuation)
        defer { waiters.removeValue(forKey: id) }
        for await _ in stream { break }
        try Task.checkCancellation()
    }
    func timeAdvanced() {
        for (_, waiter) in waiters where clock.now() >= waiter.0 {
            waiter.1.yield(()); waiter.1.finish()
        }
    }
}

actor SuspendedNavigationDevice: PoseFeedbackDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    let clock: ManualClock
    let suspendAt: Int
    private var reads = 0
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var commands: [MoveCommand] = []
    private(set) var resumed = false
    var isWaiting: Bool { gate != nil }
    init(clock: ManualClock, suspendAt: Int) { self.clock = clock; self.suspendAt = suspendAt }
    func currentPose() -> Pose? { Pose(yaw: -8) }
    func poseSample() async -> PoseSample? {
        reads += 1
        if reads == suspendAt {
            await withCheckedContinuation { gate = $0 }
            resumed = true
        }
        return PoseSample(pose: Pose(yaw: -8), receivedAt: clock.now(), sequence: UInt64(reads))
    }
    func send(_ command: MoveCommand) async throws { commands.append(command) }
    func finishSuspendedRead() { gate?.resume(); gate = nil }
}

actor NavigationCompletionProbe {
    private(set) var completed = false
    func finish() { completed = true }
}

@Test(arguments: [1, 2, 4], [false, true])
func suspendedFeedbackReturnsAtDeadlineOrCancellation(read: Int, cancel: Bool) async throws {
    let clock = ManualClock()
    let dev = SuspendedNavigationDevice(clock: clock, suspendAt: read)
    let c = GimbalController(device: dev, policy: makePolicy(), now: { clock.now() })
    let deadlines = NavigationDeadlineSleeper(clock: clock)
    let timing = RuntimeClock(now: { clock.now() }, sleep: { seconds in
        if seconds > 0.3 { try await deadlines.sleep(seconds) }
        else { try Task.checkCancellation(); clock.advance(1); await deadlines.timeAdvanced() }
    })
    let nav = GotoNavigator(controller: c, clock: timing)
    let lease = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 30)
    let probe = NavigationCompletionProbe()
    let task = Task {
        let result: Result<Pose, any Error>
        do { result = .success(try await nav.go(to: "mesa", source: lease.source, lease: lease)) }
        catch { result = .failure(error) }
        await probe.finish()
        return result
    }
    while !(await dev.isWaiting) { await Task.yield() }
    if cancel { task.cancel() }
    else {
        while !(await deadlines.isWaiting) { await Task.yield() }
        clock.advance(25); await deadlines.timeAdvanced()
    }
    for _ in 0..<1_000 {
        if await probe.completed { break }
        await Task.yield()
    }
    #expect(await probe.completed)
    #expect(await dev.commands.last == .stop)
    #expect(await c.activeLease == nil)
    if cancel { await #expect(throws: CancellationError.self) { try await task.value.get() } }
    else { await #expect(throws: NavigationError.timeout) { try await task.value.get() } }
    // The navigation has already returned without opening the reader. Clean up
    // the fixture afterwards, with a replacement lease in place.
    let replacement = try await c.requestLease(source: lease.source, zone: "mesa", seconds: 30)
    await dev.finishSuspendedRead()
    while !(await dev.resumed) { await Task.yield() }
    for _ in 0..<100 { await Task.yield() }
    #expect(await c.activeLease?.id == replacement.id)
    #expect(await dev.commands.allSatisfy { $0 == .stop })
}

actor StopHeldNavigationDevice: PoseFeedbackDevice {
    nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback]
    let feedback: SuspendedNavigationDevice
    private var stopGate: CheckedContinuation<Void, Never>?
    private(set) var commands: [MoveCommand] = []
    var stopWaiting: Bool { stopGate != nil }
    init(feedback: SuspendedNavigationDevice) { self.feedback = feedback }
    func currentPose() async -> Pose? { await feedback.currentPose() }
    func poseSample() async -> PoseSample? { await feedback.poseSample() }
    func send(_ command: MoveCommand) async throws {
        if command == .stop { await withCheckedContinuation { stopGate = $0 } }
        commands.append(command)
    }
    func finishStop() { stopGate?.resume(); stopGate = nil }
}

@Test func cancelledGotoWaitsForItsStopToFinishBeforeReturning() async throws {
    let clock = ManualClock()
    let feedback = SuspendedNavigationDevice(clock: clock, suspendAt: 1)
    let dev = StopHeldNavigationDevice(feedback: feedback)
    let c = GimbalController(device: dev, policy: makePolicy(), now: { clock.now() })
    let deadlines = NavigationDeadlineSleeper(clock: clock)
    let nav = GotoNavigator(controller: c, clock: RuntimeClock(now: { clock.now() }, sleep: {
        try await deadlines.sleep($0)
    }))
    let lease = try await c.requestLease(source: .agent("mcp"), zone: "mesa", seconds: 30)
    let probe = NavigationCompletionProbe()
    let task = Task {
        let result: Result<Pose, any Error>
        do { result = .success(try await nav.go(to: "mesa", source: lease.source, lease: lease)) }
        catch { result = .failure(error) }
        await probe.finish()
        return result
    }
    while !(await feedback.isWaiting) { await Task.yield() }
    task.cancel()
    while !(await dev.stopWaiting) { await Task.yield() }
    for _ in 0..<1_000 { await Task.yield() }
    #expect(await !probe.completed)
    #expect(await dev.commands.isEmpty)
    #expect(await c.activeLease == nil)
    await dev.finishStop()
    await #expect(throws: CancellationError.self) { try await task.value.get() }
    #expect(await probe.completed)
    #expect(await dev.commands == [.stop])
    #expect(await c.activeLease == nil)
    // The pose reader remains blocked through navigation completion.
    await feedback.finishSuspendedRead()
    while !(await feedback.resumed) { await Task.yield() }
}
