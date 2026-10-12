import Foundation
import Observation
import GimbalKit
import GimbalKitMCP

@MainActor @Observable
public final class PhoneHostModel {
    public private(set) var status = GimbalStatus(
        connected: false, referenceReady: false, battery: nil, pose: nil, lease: nil
    )
    public private(set) var zones: [ZoneRecord] = []
    public private(set) var audit: [AuditEntry] = []
    public private(set) var zoneDraft: ZoneDraft?
    public private(set) var referenceDraft: ReferenceDraft?
    public var errorMessage: String?
    public private(set) var lookOutcome: LookOutcome = .idle
    public private(set) var isLooking = false

    @ObservationIgnored private let environment: PhoneHostEnvironment
    @ObservationIgnored private let haptics: any Haptics
    @ObservationIgnored private let lookAction: @Sendable (String, UInt64) async throws -> GimbalLookResult
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var outcomeExpiry: Task<Void, Never>?

    public convenience init(environment: PhoneHostEnvironment, haptics: any Haptics = SilentHaptics()) {
        self.init(environment: environment, haptics: haptics, lookAction: { zone, token in
            try await environment.runtime.look(zone: zone, leaseSeconds: 30, stopToken: token)
        })
    }

    // Seam interno para probar resultados de «Mirar» sin ordenar movimientos reales.
    init(environment: PhoneHostEnvironment, haptics: any Haptics,
         lookAction: @escaping @Sendable (String, UInt64) async throws -> GimbalLookResult) {
        self.environment = environment
        self.haptics = haptics
        self.lookAction = lookAction
    }

    public func start() async {
        guard poller == nil else { return }
        do {
            try await environment.start()
            await refresh()
            let clock = environment.clock
            poller = Task { [weak self, clock] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refresh()
                    do { try await clock.sleep(0.2) } catch { return }
                }
            }
        } catch {
            errorMessage = "No se pudo iniciar la conexión."
        }
    }

    public func refresh() async {
        do {
            let newStatus = try await environment.runtime.status()
            let newZones = await environment.runtime.zones()
            let newAudit = await environment.runtime.auditEntries()
            status = newStatus
            zones = newZones
            audit = newAudit
        } catch {
            errorMessage = "No se pudo actualizar el estado."
        }
    }

    public func look(zone: String) async {
        guard !isLooking else { return }
        isLooking = true
        defer { isLooking = false }
        clearLookOutcome()
        let token = environment.motionStopCounter.read()
        do {
            try await environment.waitUntilConnected(timeout: 10)
            try Task.checkCancellation()
            let before = try await environment.runtime.status().pose
            let bounds = await environment.runtime.zones().first { $0.name == zone }
            let result = try await lookAction(zone, token)
            try Task.checkCancellation()
            guard environment.motionStopCounter.read() == token else { throw NavigationError.interrupted }
            showLookOutcome(.success(zone: zone, bounds: bounds, before: before, after: result.arrivalPose))
            errorMessage = nil
            haptics.success()
            await refresh()
        } catch {
            print("[GimbalKit] mirar a «\(zone)» falló: \(error)")
            let reason = LookFailureText.reason(for: error)
            errorMessage = "No se pudo mirar a \(zone): \(reason)"
            showLookOutcome(.failed(zone, reason))
            haptics.warning()
        }
    }

    private func clearLookOutcome() {
        outcomeExpiry?.cancel()
        outcomeExpiry = nil
        lookOutcome = .idle
    }

    private func showLookOutcome(_ outcome: LookOutcome) {
        clearLookOutcome()
        lookOutcome = outcome
        let clock = environment.clock
        outcomeExpiry = Task { [weak self, clock] in
            do { try await clock.sleep(6) } catch { return }
            guard !Task.isCancelled else { return }
            self?.lookOutcome = .idle
            self?.outcomeExpiry = nil
        }
    }

    public func humanStop() async {
        haptics.stopImpact()
        clearLookOutcome()
        await environment.runtime.humanStop()
        await refresh()
    }

    public func deleteZone(name: String) async {
        do {
            try await environment.runtime.deleteZone(name: name)
            if lookOutcome.zone == name { clearLookOutcome() }
            await refresh()
        } catch {
            errorMessage = error as? NavigationError == .busy
                ? "No se puede borrar la zona mientras hay otra operación en curso."
                : "No se pudo borrar la zona «\(name)»."
        }
    }

    public func prepareZone(name: String, forbidden: Bool = false) async -> ZoneDraft? {
        do {
            let draft = try await environment.runtime.prepareZone(name: name, forbidden: forbidden)
            zoneDraft = draft
            return draft
        } catch {
            zoneDraft = nil
            errorMessage = "No se pudo preparar la zona; compruebe pose y nombre."
            return nil
        }
    }

    public func cancelZone(_ draft: ZoneDraft? = nil) {
        if let draft, zoneDraft?.id != draft.id { return }
        zoneDraft = nil
    }

    public func confirmZone(_ draft: ZoneDraft) async {
        guard zoneDraft?.id == draft.id, zoneDraft?.session == draft.session else {
            errorMessage = "El borrador cambió; vuelva a preparar la zona."
            return
        }
        zoneDraft = nil
        do {
            try await environment.runtime.confirmZone(draft)
            await refresh()
        } catch {
            errorMessage = "La conexión o pose cambió; vuelva a preparar la zona."
        }
    }

    public func prepareReference() async {
        do { referenceDraft = try await environment.runtime.prepareReference() }
        catch { errorMessage = "No hay una pose fresca para preparar la referencia." }
    }

    public func cancelReference() { referenceDraft = nil }

    public func confirmReference() async {
        guard let draft = referenceDraft else { return }
        referenceDraft = nil
        do {
            try await environment.runtime.confirmReference(draft)
            await refresh()
        } catch {
            errorMessage = "La pose cambió; vuelva a preparar la referencia."
        }
    }

    public func shutdown() async {
        clearLookOutcome()
        poller?.cancel()
        poller = nil
        await environment.runtime.shutdown()
    }
}
