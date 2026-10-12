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

    @ObservationIgnored private let environment: PhoneHostEnvironment
    @ObservationIgnored private var poller: Task<Void, Never>?

    public init(environment: PhoneHostEnvironment) {
        self.environment = environment
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
        let token = environment.motionStopCounter.read()
        do {
            try await environment.waitUntilConnected(timeout: 10)
            try Task.checkCancellation()
            _ = try await environment.runtime.look(zone: zone, leaseSeconds: 30, stopToken: token)
            await refresh()
        } catch {
            errorMessage = "No se pudo mirar a \(zone). Compruebe conexión, referencia y zona."
        }
    }

    public func humanStop() async {
        await environment.runtime.humanStop()
        await refresh()
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
        poller?.cancel()
        poller = nil
        await environment.runtime.shutdown()
    }
}
