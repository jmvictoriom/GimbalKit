import Foundation

public actor GotoNavigator {
    private let controller: GimbalController
    private let clock: RuntimeClock
    private let limits = NavigationLimits()
    private var running = false
    public init(controller: GimbalController, clock: RuntimeClock = .live) {
        self.controller = controller; self.clock = clock
    }
    public func go(to zoneName: String, source: ControlSource, lease: Lease) async throws -> Pose {
        guard !running else { throw NavigationError.busy }
        guard lease.zone == zoneName, lease.source == source else { throw SafetyViolation.noLease }
        running = true
        defer { running = false }
        do {
            let deadline = clock.now().addingTimeInterval(limits.timeoutSeconds)
            return try await interruptible(until: deadline) { [self] in
                while true {
                    try Task.checkCancellation()
                    guard clock.now() < deadline else { throw NavigationError.timeout }
                    let initial = try await controller.navigationContext(source: source, lease: lease)
                    try await controller.haltNavigation(lease: lease)
                    let stoppedAt = clock.now()
                    let context = try await self.settled(after: initial.sample.sequence, stoppedAt: stoppedAt,
                                                    deadline: deadline, source: source, lease: lease)
                    let center = Pose(yaw: (context.zone.yaw.lowerBound + context.zone.yaw.upperBound) / 2,
                                      pitch: (context.zone.pitch.lowerBound + context.zone.pitch.upperBound) / 2)
                    let dy = center.yaw - context.sample.pose.yaw
                    let dp = center.pitch - context.sample.pose.pitch
                    if abs(dy) <= limits.deadband && abs(dp) <= limits.deadband {
                        try Task.checkCancellation()
                        await controller.audit.record(AuditEntry(date: clock.now(), source: source,
                                                                event: "goto \(zoneName)", outcome: .accepted))
                        try Task.checkCancellation()
                        guard clock.now() < deadline else { throw NavigationError.timeout }
                        return context.sample.pose
                    }
                    func speed(_ error: Double) -> Double {
                        abs(error) <= limits.deadband ? 0 : max(-limits.maxSpeed, min(limits.maxSpeed, error * limits.gain))
                    }
                    let velocity = Pose(yaw: speed(dy), pitch: speed(dp))
                    guard clock.now().addingTimeInterval(limits.pulseSeconds + limits.brakingSeconds) < deadline else {
                        throw NavigationError.timeout
                    }
                    try NavigationSafety.check(pose: context.sample.pose, velocity: velocity, zone: context.zone,
                                               forbidden: context.forbidden, limits: limits)
                    try await controller.navigationPulse(velocity, source: source, lease: lease)
                    try await clock.sleep(limits.pulseSeconds)
                    try await controller.haltNavigation(lease: lease)
                }
            }
        } catch {
            await controller.release(lease: lease)
            let reason = Task.isCancelled ? "cancelled" : String(String(describing: error).prefix { $0 != "(" })
            await controller.audit.record(AuditEntry(date: clock.now(), source: source,
                                                    event: "goto \(zoneName)", outcome: .rejected(reason)))
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
    // Unstructured readers may be non-cooperative. The signal lets the caller
    // return without joining them; cancellation and controller epochs prevent
    // a late reader from issuing a command after its lease was released.
    private func interruptible<Value: Sendable>(until deadline: Date,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let signal = NavigationResult<Value>()
        let reader = Task {
            do { await signal.finish(.success(try await operation())) }
            catch { await signal.finish(.failure(error)) }
        }
        let clock = clock
        let timer = Task {
            do {
                while clock.now() < deadline {
                    try Task.checkCancellation()
                    try await clock.sleep(deadline.timeIntervalSince(clock.now()))
                }
                try Task.checkCancellation()
                await signal.finish(.failure(NavigationError.timeout))
            } catch {
                if !Task.isCancelled { await signal.finish(.failure(error)) }
            }
        }
        defer { reader.cancel(); timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await signal.value()
        } onCancel: {
            Task { await signal.finish(.failure(CancellationError())) }
        }
    }

    private func settled(after initial: UInt64, stoppedAt: Date, deadline: Date,
                         source: ControlSource, lease: Lease) async throws -> NavigationContext {
        var mark = initial
        var newSamples = 0
        while true {
            try Task.checkCancellation()
            guard clock.now() < deadline else { throw NavigationError.timeout }
            let context = try await controller.navigationContext(source: source, lease: lease)
            guard clock.now() < deadline else { throw NavigationError.timeout }
            if context.sample.sequence != mark {
                mark = context.sample.sequence
                if context.sample.receivedAt >= stoppedAt { newSamples += 1 }
            }
            if newSamples >= 2,
               context.sample.receivedAt.timeIntervalSince(stoppedAt) >= limits.settleSeconds { return context }
            try await clock.sleep(0.1)
        }
    }
}

/// Resolves once even when cancellation arrives before the waiter is installed.
private actor NavigationResult<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var waiter: CheckedContinuation<Value, any Error>?
    func finish(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        waiter?.resume(with: result)
        waiter = nil
    }
    func value() async throws -> Value {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}
