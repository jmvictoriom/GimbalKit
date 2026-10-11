import Foundation

public actor GimbalController {
    private let device: any GimbalDevice
    private let policy: SafetyPolicy
    private let now: @Sendable () -> Date
    public let audit: AuditLog

    private var lease: Lease?
    private var movingBySpeed = false
    private var lastSpeedAt: Date?

    public init(
        device: any GimbalDevice,
        policy: SafetyPolicy,
        now: @escaping @Sendable () -> Date = { Date() },
        audit: AuditLog = AuditLog()
    ) {
        self.device = device
        self.policy = policy
        self.now = now
        self.audit = audit
    }

    /// El lease vigente (nil si no hay o ya caducó).
    public var activeLease: Lease? {
        guard let lease, lease.expiresAt > now() else { return nil }
        return lease
    }

    // MARK: Leases

    public func requestLease(source: ControlSource, zone name: String, seconds: Double) async throws -> Lease {
        do {
            guard seconds.isFinite, seconds > 0 else { throw SafetyViolation.invalidDuration }
            guard seconds <= policy.maxLeaseSeconds else { throw SafetyViolation.leaseTooLong(max: policy.maxLeaseSeconds) }
            guard let zone = policy.zone(named: name) else { throw SafetyViolation.unknownZone(name) }
            guard !zone.forbidden else { throw SafetyViolation.forbiddenZone(name) }
            if let active = activeLease, active.source != source {
                guard source.isPrivileged else { throw SafetyViolation.busy(holder: active.source) }
                await revokeLease(reason: "preempted by \(source)")
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

    // MARK: Órdenes

    public func send(_ command: MoveCommand, source: ControlSource, lease presented: Lease? = nil) async throws {
        do {
            // La pose se lee ANTES de validar: entre la comprobación del lease y el envío no puede haber
            // ninguna espera, o un stop() concurrente se colaría y la orden saldría después de la parada.
            var pose: Pose?
            if case .speed = command, device.capabilities.contains(.poseFeedback) {
                pose = await device.currentPose()
            }
            try validate(command, source: source, presented: presented, pose: pose)
            try await device.send(command)
            switch command {
            case let .speed(yaw, pitch, roll):
                movingBySpeed = !(yaw == 0 && pitch == 0 && roll == 0)
                lastSpeedAt = now()
            case .absolute, .stop:
                movingBySpeed = false
            }
            await record(source, "\(command)", .accepted)
        } catch {
            await record(source, "\(command)", .rejected(Self.describe(error)))
            throw error
        }
    }

    private func validate(_ command: MoveCommand, source: ControlSource, presented: Lease?, pose current: Pose?) throws {
        if case .stop = command { return }
        let caps = device.capabilities
        switch command {
        case let .speed(yaw, pitch, roll):
            guard caps.contains(.speedControl) else { throw SafetyViolation.unsupported(.speedControl) }
            guard yaw.isFinite, pitch.isFinite, roll.isFinite else { throw SafetyViolation.invalidValue }
            let peak = max(abs(yaw), abs(pitch), abs(roll))
            guard peak <= policy.maxSpeed else { throw SafetyViolation.speedTooHigh(limit: policy.maxSpeed, requested: peak) }
        case let .absolute(pose, seconds):
            guard caps.contains(.absoluteControl) else { throw SafetyViolation.unsupported(.absoluteControl) }
            guard pose.isFinite, seconds.isFinite, seconds >= 0 else { throw SafetyViolation.invalidValue }
        case .stop:
            return
        }
        if source.isPrivileged { return }

        guard let active = activeLease else {
            throw presented == nil ? SafetyViolation.noLease : SafetyViolation.leaseExpired
        }
        guard presented?.id == active.id, active.source == source else { throw SafetyViolation.noLease }
        guard let zone = policy.zone(named: active.zone) else { throw SafetyViolation.unknownZone(active.zone) }

        switch command {
        case let .absolute(pose, _):
            if let forbidden = policy.forbiddenZone(containing: pose) { throw SafetyViolation.forbiddenZone(forbidden.name) }
            guard zone.contains(pose) else { throw SafetyViolation.outsideZone(zone.name) }
        case .speed:
            guard caps.contains(.poseFeedback), let pose = current else { throw SafetyViolation.poseUnavailable }
            if let forbidden = policy.forbiddenZone(containing: pose) { throw SafetyViolation.forbiddenZone(forbidden.name) }
            guard zone.contains(pose) else { throw SafetyViolation.outsideZone(zone.name) }
        case .stop:
            break
        }
    }

    // MARK: Parada, deadman y desconexión

    /// Siempre envía parada. Una fuente privilegiada además revoca el lease; otra solo el suyo.
    public func stop(source: ControlSource) async {
        // Primero se invalida el estado (sin esperas) y después se avisa al dispositivo.
        movingBySpeed = false
        if source.isPrivileged || lease?.source == source { lease = nil }
        try? await device.send(.stop)
        await record(source, "stop", .accepted)
    }

    /// Debe llamarse con frecuencia (≤100 ms) mientras haya movimiento. Aplica caducidad de lease,
    /// deadman y salida de zona.
    public func tick() async {
        let t = now()
        if let lease, lease.expiresAt <= t {
            await revokeLease(reason: "expired")
            return
        }
        guard movingBySpeed else { return }
        if let last = lastSpeedAt, t.timeIntervalSince(last) > policy.deadmanSeconds {
            await emergencyStop("deadman")
            return
        }
        if let lease, !lease.source.isPrivileged,
           let zone = policy.zone(named: lease.zone),
           let pose = await device.currentPose(),
           !zone.contains(pose) || policy.forbiddenZone(containing: pose) != nil {
            await emergencyStop("left zone")
        }
    }

    public func deviceDisconnected() async {
        lease = nil
        movingBySpeed = false
        await record(nil, "device disconnected", .accepted)
    }

    private func emergencyStop(_ reason: String) async {
        try? await device.send(.stop)
        movingBySpeed = false
        await record(nil, "emergency stop: \(reason)", .accepted)
    }

    // MARK: Utilidades internas (las usa también la Task 6)

    func revokeLease(reason: String) async {
        let source = lease?.source
        lease = nil
        try? await device.send(.stop)
        movingBySpeed = false
        await record(source, "lease revoked: \(reason)", .accepted)
    }

    func record(_ source: ControlSource?, _ event: String, _ outcome: AuditEntry.Outcome) async {
        await audit.record(AuditEntry(date: now(), source: source, event: event, outcome: outcome))
    }

    static func describe(_ error: any Error) -> String {
        if let violation = error as? SafetyViolation {
            // Solo el nombre del caso, sin argumentos: p. ej. "noLease", "speedTooHigh".
            return String(String(describing: violation).prefix { $0 != "(" })
        }
        return String(describing: error)
    }
}
