import Foundation
import GimbalKit
import GimbalKitDJI
import GimbalKitMCP

public protocol HostLink: OMTransport {
    var disconnects: AsyncStream<Void> { get }
    func connect() async throws
    func disconnect() async
}
public struct ZoneDraft: Sendable {
    public let id: UUID
    public let session: UUID
    public let zone: Zone
    public let pose: Pose
}
public struct ReferenceDraft: Sendable {
    public let id: UUID
    public let session: UUID
    public let pose: Pose
}
public actor HostRuntime: GimbalService {
    private struct Rig {
        let id: UUID
        let link: any HostLink
        let device: OMDevice
        let controller: GimbalController
        let navigator: GotoNavigator
    }
    public nonisolated let motionStopCounter: MotionStopCounter
    private let makeLink: @Sendable () -> any HostLink
    private let store: ZoneStore
    private let clock: RuntimeClock
    private let audit = AuditLog()
    private var savedZones: [Zone] = []
    private var rig: Rig?
    private var referenceReady = false
    private var pendingZone: ZoneDraft?
    private var pendingReference: ReferenceDraft?
    private var connecting: (UUID, any HostLink)?
    private var loop: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var generation = UUID()
    private var started = false
    private var looking = false
    private var editing = false

    public init(
        makeLink: @escaping @Sendable () -> any HostLink,
        store: ZoneStore,
        clock: RuntimeClock = .live,
        motionStopCounter: MotionStopCounter = MotionStopCounter()
    ) {
        self.makeLink = makeLink
        self.store = store
        self.clock = clock
        self.motionStopCounter = motionStopCounter
    }
    public static func backoff(_ failure: Int) -> Double { min(8, 0.5 * pow(2, Double(min(4, max(0, failure))))) }
    public func start() async throws {
        guard !started else { return }
        started = true
        let current = UUID(); generation = current
        let loaded: [Zone]
        do { loaded = try await store.load() }
        catch { if generation == current { started = false }; throw error }
        guard started, generation == current else { return }
        savedZones = loaded
        ticker = Task { [weak self, clock] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tickOnce()
                do { try await clock.sleep(0.1) } catch { break }
            }
        }
        loop = Task { [weak self] in await self?.connectLoop(generation: current) }
    }
    private func connectLoop(generation current: UUID) async {
        var failures = 0
        while !Task.isCancelled, started, generation == current {
            let link = makeLink()
            let id = UUID()
            connecting = (id, link)
            do {
                try await link.connect()
                try Task.checkCancellation()
                guard started, generation == current else { throw CancellationError() }
                connecting = nil
                let device = OMDevice(transport: link, now: clock.now)
                let policy = SafetyPolicy(maxSpeed: 6, maxLeaseSeconds: 30, deadmanSeconds: 0.5, zones: [])
                let controller = GimbalController(device: device, policy: policy, now: clock.now, audit: audit)
                let active = Rig(id: id, link: link, device: device, controller: controller,
                                 navigator: GotoNavigator(controller: controller, clock: clock))
                rig = active; referenceReady = false; pendingZone = nil; pendingReference = nil
                await device.start()
                await log("connected; reference confirmation required")
                failures = 0
                for await _ in link.disconnects { break }
                if rig?.id == id {
                    rig = nil; referenceReady = false; pendingZone = nil; pendingReference = nil
                    await controller.deviceDisconnected()
                }
                await device.shutdown()
            } catch {
                if connecting?.0 == id { connecting = nil }
                await log(error is CancellationError ? "connection cancelled" : "connection failed")
            }
            await link.disconnect()
            guard !Task.isCancelled, started, generation == current else { break }
            do { try await clock.sleep(Self.backoff(failures)) } catch { break }
            failures += 1
        }
    }
    public func shutdown() async {
        started = false; generation = UUID()
        let oldLoop = loop, oldTicker = ticker
        loop = nil; ticker = nil; oldLoop?.cancel(); oldTicker?.cancel()
        let old = rig; rig = nil; referenceReady = false; pendingZone = nil; pendingReference = nil
        if let old { await old.controller.stop(source: .app); await old.device.shutdown(); await old.link.disconnect() }
        if let pending = connecting { connecting = nil; await pending.1.disconnect() }
        await oldLoop?.value; await oldTicker?.value
    }
    public func tickOnce() async { if let rig { await rig.controller.tick() } }
    public func auditEntries() async -> [AuditEntry] { await audit.entries() }
    public func status() async throws -> GimbalStatus {
        guard let captured = rig else { return GimbalStatus(connected: false, referenceReady: false, battery: nil, pose: nil, lease: nil) }
        let sample = await captured.device.poseSample()
        let battery = await captured.device.battery
        let lease = await captured.controller.activeLease
        guard rig?.id == captured.id else { return GimbalStatus(connected: false, referenceReady: false, battery: nil, pose: nil, lease: nil) }
        let fresh = sample.flatMap { sample -> Pose? in
            let age = clock.now().timeIntervalSince(sample.receivedAt)
            return age >= 0 && age <= 1.5 ? sample.pose : nil
        }
        return GimbalStatus(connected: true, referenceReady: referenceReady,
                            battery: battery.map { BatteryStatus(percent: $0.percent, charging: $0.charging) }, pose: fresh,
                            lease: lease.map { LeaseStatus(zone: $0.zone, expiresAt: $0.expiresAt, remainingSeconds: max(0, $0.expiresAt.timeIntervalSince(clock.now()))) })
    }
    public func zones() -> [ZoneRecord] { savedZones.map(ZoneRecord.init) }
    public func deleteZone(name: String) async throws {
        guard !looking, !editing else { throw NavigationError.busy }
        guard savedZones.contains(where: { $0.name == name }) else { throw ZoneStoreError.invalidZone }
        editing = true
        defer { editing = false }
        let updated = savedZones.filter { $0.name != name }
        try await store.save(updated)
        savedZones = updated
        if let current = rig { await current.controller.replaceZones(updated) }
        await log("zone deleted: \(name)")
    }
    public func look(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult {
        try await look(zone: zone, leaseSeconds: leaseSeconds, stopToken: nil)
    }

    public func look(zone: String, leaseSeconds: Double, stopToken: UInt64?) async throws -> GimbalLookResult {
        if let stopToken {
            guard motionStopCounter.read() == stopToken else { throw NavigationError.interrupted }
        }
        guard let captured = rig else { throw SafetyViolation.poseUnavailable }
        guard referenceReady else { throw NavigationError.referenceRequired }
        guard leaseSeconds.isFinite, leaseSeconds > 0, leaseSeconds <= 30 else { throw SafetyViolation.invalidDuration }
        guard !looking, !editing else { throw NavigationError.busy }
        looking = true
        defer { looking = false }
        let existingLease = await captured.controller.activeLease
        if let stopToken {
            guard motionStopCounter.read() == stopToken else { throw NavigationError.interrupted }
        }
        if let existingLease { throw SafetyViolation.busy(holder: existingLease.source) }
        guard rig?.id == captured.id, referenceReady else { throw NavigationError.interrupted }
        let lease: Lease
        do {
            lease = try await captured.controller.requestLease(source: .agent("mcp"), zone: zone, seconds: leaseSeconds)
        } catch {
            if let stopToken {
                guard motionStopCounter.read() == stopToken else { throw NavigationError.interrupted }
            }
            throw error
        }
        if let stopToken {
            guard motionStopCounter.read() == stopToken else {
                await captured.controller.release(lease: lease)
                throw NavigationError.interrupted
            }
        }
        do {
            let arrival = try await captured.navigator.go(to: zone, source: .agent("mcp"), lease: lease)
            return GimbalLookResult(status: try await status(), arrivalPose: arrival)
        } catch {
            await captured.controller.release(lease: lease)
            throw error
        }
    }

    public func stop() async throws {
        motionStopCounter.increment()
        if let rig { await rig.controller.stop(source: .agent("mcp")) }
    }

    public func humanStop() async {
        motionStopCounter.increment()
        if let rig { await rig.controller.stop(source: .app) }
    }
    private func freshRig() async throws -> (Rig, Pose) {
        guard let captured = rig, let sample = await captured.device.poseSample(), sample.pose.isFinite else {
            throw SafetyViolation.poseUnavailable
        }
        guard rig?.id == captured.id else { throw NavigationError.interrupted }
        let age = clock.now().timeIntervalSince(sample.receivedAt)
        guard age >= 0, age <= 1.5 else { throw NavigationError.stalePose }
        return (captured, sample.pose)
    }
    public func prepareZone(name: String, forbidden: Bool = false) async throws -> ZoneDraft {
        let (captured, pose) = try await freshRig()
        guard !looking, !editing, referenceReady || savedZones.isEmpty else { throw NavigationError.referenceRequired }
        let zone = Zone(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        yaw: (pose.yaw - 10)...(pose.yaw + 10), pitch: (pose.pitch - 10)...(pose.pitch + 10), forbidden: forbidden)
        _ = try ZoneRecord(zone).zone()
        guard !savedZones.contains(where: { $0.name == zone.name }) else { throw ZoneStoreError.invalidZone }
        let draft = ZoneDraft(id: UUID(), session: captured.id, zone: zone, pose: pose)
        pendingZone = draft
        return draft
    }
    public func confirmZone(_ draft: ZoneDraft) async throws {
        let (captured, pose) = try await freshRig()
        guard pendingZone?.id == draft.id, captured.id == draft.session, !looking, !editing,
              abs(pose.yaw - draft.pose.yaw) <= 2, abs(pose.pitch - draft.pose.pitch) <= 2 else { throw NavigationError.interrupted }
        editing = true
        defer { editing = false }
        pendingZone = nil
        let updated = savedZones + [draft.zone]
        try await store.save(updated)
        savedZones = updated
        guard rig?.id == captured.id else { throw NavigationError.interrupted }
        referenceReady = true
        await captured.controller.replaceZones(updated)
        await log("zone saved: \(draft.zone.name)")
    }
    public func prepareReference() async throws -> ReferenceDraft {
        let (captured, pose) = try await freshRig()
        guard !looking, !editing else { throw NavigationError.busy }
        let draft = ReferenceDraft(id: UUID(), session: captured.id, pose: pose)
        pendingReference = draft
        return draft
    }
    public func confirmReference(_ draft: ReferenceDraft) async throws {
        let (captured, pose) = try await freshRig()
        guard pendingReference?.id == draft.id, captured.id == draft.session, !looking, !editing,
              abs(pose.yaw - draft.pose.yaw) <= 2, abs(pose.pitch - draft.pose.pitch) <= 2 else { throw NavigationError.interrupted }
        editing = true
        defer { editing = false }
        pendingReference = nil
        await captured.controller.replaceZones(savedZones)
        guard rig?.id == captured.id else { throw NavigationError.interrupted }
        referenceReady = true
        await log("reference confirmed by human")
    }
    private func log(_ event: String) async {
        await audit.record(AuditEntry(date: clock.now(), source: .app, event: event, outcome: .accepted))
    }
}
