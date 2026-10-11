import Foundation

public actor GimbalController {
    private let device: any GimbalDevice
    private var policy: SafetyPolicy
    private let now: @Sendable () -> Date
    public let audit: AuditLog
    private var lease: Lease?
    private var movingBySpeed = false
    private var lastSpeedAt: Date?
    private var lastNavigationSpeedAt: Date?
    private var epoch: UInt64 = 0
    private struct Job {
        let command: MoveCommand
        let epoch: UInt64
        let completion: CheckedContinuation<Void, any Error>
    }
    private var jobs: [Job] = []
    private var pumping = false
    private let limits = NavigationLimits()

    public init(device: any GimbalDevice, policy: SafetyPolicy,
                now: @escaping @Sendable () -> Date = RuntimeClock.live.now, audit: AuditLog = AuditLog()) {
        self.device = device; self.policy = policy; self.now = now; self.audit = audit
    }
    public var activeLease: Lease? {
        guard let lease, lease.expiresAt > now() else { return nil }
        return lease
    }
    public var zones: [Zone] { policy.zones }
    public func replaceZones(_ zones: [Zone]) async {
        invalidate()
        policy.zones = zones
        try? await enqueue(.stop)
        await record(.app, "zones replaced", .accepted)
    }
    public func requestLease(source: ControlSource, zone name: String, seconds: Double) async throws -> Lease {
        do {
            guard seconds.isFinite, seconds > 0 else { throw SafetyViolation.invalidDuration }
            guard seconds <= policy.maxLeaseSeconds else { throw SafetyViolation.leaseTooLong(max: policy.maxLeaseSeconds) }
            guard let zone = policy.zone(named: name) else { throw SafetyViolation.unknownZone(name) }
            guard !zone.forbidden else { throw SafetyViolation.forbiddenZone(name) }
            if let active = activeLease, active.source != source {
                guard source.isPrivileged else { throw SafetyViolation.busy(holder: active.source) }
                invalidate()
                // Reservar antes del await evita que otro solicitante se cuele durante la parada.
                lease = Lease(source: source, zone: name, expiresAt: now().addingTimeInterval(seconds))
                let reserved = lease!
                try await enqueue(.stop)
                guard lease?.id == reserved.id else { throw NavigationError.interrupted }
                await record(source, "lease \(name) \(seconds)s", .accepted)
                return reserved
            }
            let granted = Lease(source: source, zone: name, expiresAt: now().addingTimeInterval(seconds))
            lease = granted
            await record(source, "lease \(name) \(seconds)s", .accepted)
            return granted
        } catch {
            await record(source, "lease \(name)", .rejected(Self.describe(error)))
            throw error
        }
    }
    public func send(_ command: MoveCommand, source: ControlSource, lease presented: Lease? = nil) async throws {
        do {
            let before = epoch
            var pose: Pose?
            if case .speed = command, device.capabilities.contains(.poseFeedback) { pose = await device.currentPose() }
            try validate(command, source: source, presented: presented, pose: pose)
            guard before == epoch else { throw NavigationError.interrupted }
            try Task.checkCancellation()
            let sentEpoch = epoch
            try await enqueue(command)
            if sentEpoch == epoch {
                switch command {
                case let .speed(y, p, r): movingBySpeed = y != 0 || p != 0 || r != 0; lastSpeedAt = now()
                case .absolute, .stop: movingBySpeed = false
                }
            }
            await record(source, "\(command)", .accepted)
        } catch {
            await record(source, "\(command)", .rejected(Self.describe(error)))
            throw error
        }
    }
    private func validate(_ command: MoveCommand, source: ControlSource, presented: Lease?, pose: Pose?) throws {
        if case .stop = command { return }
        switch command {
        case let .speed(y, p, r):
            guard device.capabilities.contains(.speedControl) else { throw SafetyViolation.unsupported(.speedControl) }
            guard y.isFinite, p.isFinite, r.isFinite else { throw SafetyViolation.invalidValue }
            let peak = max(abs(y), abs(p), abs(r))
            guard peak <= policy.maxSpeed else { throw SafetyViolation.speedTooHigh(limit: policy.maxSpeed, requested: peak) }
        case let .absolute(p, seconds):
            guard device.capabilities.contains(.absoluteControl) else { throw SafetyViolation.unsupported(.absoluteControl) }
            guard p.isFinite, seconds.isFinite, seconds >= 0 else { throw SafetyViolation.invalidValue }
        case .stop: return
        }
        if source.isPrivileged { return }
        guard let active = activeLease else { throw presented == nil ? SafetyViolation.noLease : SafetyViolation.leaseExpired }
        guard presented?.id == active.id, source == active.source else { throw SafetyViolation.noLease }
        guard let zone = policy.zone(named: active.zone) else { throw SafetyViolation.unknownZone(active.zone) }
        let checked: Pose
        switch command {
        case let .absolute(p, _): checked = p
        case .speed:
            guard device.capabilities.contains(.poseFeedback), let pose else { throw SafetyViolation.poseUnavailable }
            checked = pose
        case .stop: return
        }
        if let f = policy.forbiddenZone(containing: checked) { throw SafetyViolation.forbiddenZone(f.name) }
        guard zone.contains(checked) else { throw SafetyViolation.outsideZone(zone.name) }
    }
    public func navigationContext(source: ControlSource, lease presented: Lease) async throws -> NavigationContext {
        let before = epoch
        guard let feedback = device as? any PoseFeedbackDevice,
              let sample = await feedback.poseSample() else { throw SafetyViolation.poseUnavailable }
        try validate(.speed(yaw: 0, pitch: 0, roll: 0), source: source, presented: presented, pose: sample.pose)
        guard before == epoch, activeLease?.id == presented.id, presented.source == source else { throw NavigationError.interrupted }
        let age = now().timeIntervalSince(sample.receivedAt)
        guard age >= 0, age <= limits.staleSeconds else { throw NavigationError.stalePose }
        return NavigationContext(zone: policy.zone(named: presented.zone)!,
                                 forbidden: policy.zones.filter(\.forbidden), sample: sample)
    }
    public func navigationPulse(_ velocity: Pose, source: ControlSource, lease: Lease) async throws {
        let context = try await navigationContext(source: source, lease: lease)
        try Task.checkCancellation()
        let command = MoveCommand.speed(yaw: velocity.yaw, pitch: velocity.pitch, roll: velocity.roll)
        try validate(command, source: source, presented: lease, pose: context.sample.pose)
        try NavigationSafety.check(pose: context.sample.pose, velocity: velocity, zone: context.zone,
                                   forbidden: context.forbidden, limits: limits)
        if let last = lastNavigationSpeedAt, now().timeIntervalSince(last) < limits.pulseSeconds {
            throw NavigationError.unsafePath
        }
        guard activeLease?.id == lease.id else { throw NavigationError.interrupted }
        let e = epoch
        lastNavigationSpeedAt = now()
        movingBySpeed = true; lastSpeedAt = now()
        try await enqueue(command)
        guard e == epoch else { throw NavigationError.interrupted }
        await record(source, "navigation pulse \(lease.zone)", .accepted)
    }
    public func haltNavigation(lease presented: Lease) async throws {
        guard lease?.id == presented.id else { throw NavigationError.interrupted }
        movingBySpeed = false
        try await enqueue(.stop)
    }
    public func release(lease presented: Lease) async {
        guard lease?.id == presented.id else { return }
        invalidate()
        try? await enqueue(.stop)
        await record(presented.source, "lease released", .accepted)
    }
    public func stop(source: ControlSource) async {
        epoch &+= 1; movingBySpeed = false
        if source.isPrivileged || lease?.source == source { lease = nil }
        try? await enqueue(.stop)
        await record(source, "stop", .accepted)
    }
    public func tick() async {
        if let lease, lease.expiresAt <= now() { await revokeLease(reason: "expired"); return }
        guard movingBySpeed else { return }
        if let lastSpeedAt, now().timeIntervalSince(lastSpeedAt) > policy.deadmanSeconds {
            await revokeLease(reason: "deadman"); return
        }
        let before = epoch
        if let lease, !lease.source.isPrivileged, let zone = policy.zone(named: lease.zone),
           let pose = await device.currentPose(), before == epoch,
           !zone.contains(pose) || policy.forbiddenZone(containing: pose) != nil {
            await revokeLease(reason: "left zone")
        }
    }
    public func deviceDisconnected() async {
        invalidate()
        await record(nil, "device disconnected", .accepted)
    }
    private func invalidate() { epoch &+= 1; lease = nil; movingBySpeed = false }
    func revokeLease(reason: String) async {
        let source = lease?.source
        invalidate()
        try? await enqueue(.stop)
        await record(source, "lease revoked: \(reason)", .accepted)
    }
    private func enqueue(_ command: MoveCommand) async throws {
        try await withCheckedThrowingContinuation { continuation in
            jobs.append(Job(command: command, epoch: epoch, completion: continuation))
            if !pumping { pumping = true; Task { await self.pump() } }
        }
    }
    private func pump() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            if job.command != .stop, job.epoch != epoch {
                job.completion.resume(throwing: NavigationError.interrupted); continue
            }
            do { try await device.send(job.command); job.completion.resume() }
            catch { job.completion.resume(throwing: error) }
        }
        pumping = false
    }
    func record(_ source: ControlSource?, _ event: String, _ outcome: AuditEntry.Outcome) async {
        await audit.record(AuditEntry(date: now(), source: source, event: event, outcome: outcome))
    }
    static func describe(_ error: any Error) -> String {
        String(String(describing: error).prefix { $0 != "(" })
    }
}
