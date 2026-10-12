import Foundation
import GimbalKit
import GimbalKitMCP
import GimbalWatchKit

public protocol PhoneWatchRuntime: Sendable {
    var motionStopCounter: MotionStopCounter { get }
    func look(zone: String, leaseSeconds: Double, stopToken: UInt64?) async throws -> GimbalLookResult
    func humanStop() async
    func status() async throws -> GimbalStatus
    func zones() async -> [ZoneRecord]
}

extension HostRuntime: PhoneWatchRuntime {}

public enum PhoneWatchOutput: Sendable, Equatable {
    case event(WatchEventEnvelope)
    case status(WatchStatus)
}

public enum PhoneWatchEventPublication: Sendable, Equatable {
    case send(WatchEventEnvelope)
    case discard
    case correctStaleArrival(WatchEventEnvelope)

    public static func decision(for envelope: WatchEventEnvelope, currentStopCounter: UInt64) -> Self {
        switch envelope.event {
        case let .arrived(id, token) where token != currentStopCounter:
            return .correctStaleArrival(WatchEventEnvelope(
                session: envelope.session,
                event: .stopped(operationID: id, stopCounter: token)
            ))
        case let .stopped(_, token) where token != currentStopCounter:
            return .discard
        default:
            return .send(envelope)
        }
    }

    /// Usar desde el ejecutor del bridge: el closure llama a WatchConnectivity
    /// síncronamente bajo el lock de STOP. El resultado permite corregir después
    /// el terminal del servicio con replaceLatestTerminalEvent(_:replacing:).
    /// No suspender ni acceder otra vez al contador dentro de send.
    @discardableResult
    public static func publish(
        _ value: PhoneWatchOutput,
        stopCounter: MotionStopCounter,
        send: (PhoneWatchOutput) -> Void
    ) -> PhoneWatchOutput? {
        stopCounter.withValue { current in
            guard let prepared = preparedOutput(value, current: current) else { return nil }
            send(prepared)
            return prepared
        }
    }

    fileprivate static func preparedOutput(_ value: PhoneWatchOutput, current: UInt64) -> PhoneWatchOutput? {
        switch value {
        case let .event(envelope):
            switch decision(for: envelope, currentStopCounter: current) {
            case .discard: return nil
            case let .send(event), let .correctStaleArrival(event): return .event(event)
            }
        case let .status(status):
            return .status(WatchStatus(stopToken: current, connected: status.connected,
                batteryPercent: status.batteryPercent, pose: status.pose, zoneNames: status.zoneNames,
                terminalEvent: correctedTerminal(status.terminalEvent, current: current)))
        }
    }

    fileprivate static func correctedTerminal(_ envelope: WatchEventEnvelope?, current: UInt64) -> WatchEventEnvelope? {
        guard let envelope else { return nil }
        if case let .correctStaleArrival(correction) = decision(for: envelope, currentStopCounter: current) {
            return correction
        }
        // El contexto conserva stopped para recuperar la operación, aunque su token sea antiguo.
        return envelope
    }

}

public actor PhoneWatchService {
    private struct Operation: Sendable, Equatable {
        let session: UUID
        let seq: UInt64
        let id: UUID
        let token: UInt64
    }

    public nonisolated let outputs: AsyncStream<PhoneWatchOutput>
    public nonisolated let stopCounter: MotionStopCounter
    private let output: AsyncStream<PhoneWatchOutput>.Continuation
    private let runtime: any PhoneWatchRuntime
    private let clock: RuntimeClock
    private var lastSequenceBySession: [UUID: UInt64] = [:]
    private var stopSequenceBySession: [UUID: UInt64] = [:]
    private var zoneNames = Set<String>()
    private var latestTerminalEvent: WatchEventEnvelope?
    private var terminalRevision: UInt64 = 0
    private var active: Operation?
    private var reachable = true
    private var quietUntil: Date?
    private var observedStopCounter: UInt64
    private var observer: Task<Void, Never>?

    public init(runtime: any PhoneWatchRuntime, clock: RuntimeClock = .live) {
        let pair = AsyncStream.makeStream(of: PhoneWatchOutput.self)
        self.outputs = pair.stream
        self.stopCounter = runtime.motionStopCounter
        self.output = pair.continuation
        self.runtime = runtime
        self.clock = clock
        self.observedStopCounter = runtime.motionStopCounter.read()
    }

    public var watchOperationActive: Bool { active != nil }

    public func startObservingStopCounter() {
        guard observer == nil else { return }
        let clock = self.clock
        observer = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(0.025) } catch { return }
                guard let self else { return }
                await self.refreshStatus()
            }
        }
    }

    public func shutdown() {
        observer?.cancel()
        observer = nil
        output.finish()
    }

    public func receive(_ request: WatchRequest) async {
        observeCounterChange()
        if case .stop = request.command {
            await stop(request)
            return
        }
        if case .look(_) = request.command,
           let stopSeq = stopSequenceBySession[request.session], request.seq <= stopSeq {
            reject(session: request.session, id: request.operationID ?? UUID(), reason: .staleAfterStop)
            return
        }
        guard acceptSequence(request) else { return }

        switch request.command {
        case let .look(zone):
            await look(zone: zone, request: request)
        case .status:
            await sendStatus()
        case .stop:
            return
        }
    }

    public func rejectMalformed(session: UUID?, operationID: UUID?) {
        reject(session: session, id: operationID ?? UUID(), reason: .malformed)
    }

    public func refreshStatus() async {
        await sendStatus()
    }

    /// Corrige únicamente el terminal que todavía corresponde al evento encolado.
    public func replaceLatestTerminalEvent(_ envelope: WatchEventEnvelope, replacing original: WatchEventEnvelope) {
        guard latestTerminalEvent == original else { return }
        latestTerminalEvent = envelope
    }

    /// Variante aislada para consumidores sin un ejecutor de UI propio.
    /// Validación, corrección del terminal y envío son síncronos bajo el lock.
    /// No volver a entrar en el contador ni en este servicio desde send.
    public func publish(_ value: PhoneWatchOutput, send: (PhoneWatchOutput) -> Void) {
        stopCounter.withValue { current in
            observeCounterChange(current: current)
            guard let prepared = PhoneWatchEventPublication.preparedOutput(value, current: current) else { return }
            switch (value, prepared) {
            case let (.event(original), .event(correction)):
                replaceLatestTerminalEvent(correction, replacing: original)
            case let (.status(original), .status(correction)):
                if let original = original.terminalEvent, let correction = correction.terminalEvent {
                    replaceLatestTerminalEvent(correction, replacing: original)
                }
            default: break
            }
            send(prepared)
        }
    }

    public func setReachable(_ isReachable: Bool) async {
        observeCounterChange()
        reachable = isReachable
        guard !isReachable, let operation = active else { return }
        quietUntil = clock.now().addingTimeInterval(2)
        active = nil
        let terminalRevisionBeforeStop = terminalRevision
        await runtime.humanStop()
        observeCounterChange()
        let remember = terminalRevision == terminalRevisionBeforeStop
        emit(WatchEventEnvelope(
            session: operation.session,
            event: .stopped(operationID: operation.id, stopCounter: operation.token)
        ), remember: remember)
    }

    private func acceptSequence(_ request: WatchRequest) -> Bool {
        if let previous = lastSequenceBySession[request.session], request.seq <= previous {
            reject(session: request.session, id: request.operationID ?? UUID(), reason: .outOfOrder)
            return false
        }
        lastSequenceBySession[request.session] = request.seq
        return true
    }

    private func stop(_ request: WatchRequest) async {
        let stopID = request.operationID ?? UUID()
        quietUntil = clock.now().addingTimeInterval(2)
        let old = active
        active = nil
        if lastSequenceBySession[request.session].map({ request.seq > $0 }) ?? true {
            lastSequenceBySession[request.session] = request.seq
        }
        if stopSequenceBySession[request.session].map({ request.seq > $0 }) ?? true {
            stopSequenceBySession[request.session] = request.seq
        }
        let terminalRevisionBeforeStop = terminalRevision
        await runtime.humanStop()
        observeCounterChange()
        let remember = terminalRevision == terminalRevisionBeforeStop
        if let old {
            emit(WatchEventEnvelope(
                session: old.session,
                event: .stopped(operationID: old.id, stopCounter: old.token)
            ), remember: remember)
        }
        emit(WatchEventEnvelope(
            session: request.session,
            event: .stopped(operationID: stopID, stopCounter: observedStopCounter)
        ), remember: remember)
    }

    private func look(zone: String, request: WatchRequest) async {
        guard let id = request.operationID else {
            reject(session: request.session, id: UUID(), reason: .malformed)
            return
        }
        if let quietUntil, clock.now() < quietUntil {
            reject(session: request.session, id: id, reason: .quietPeriod)
            return
        }
        guard reachable else {
            reject(session: request.session, id: id, reason: .disconnected)
            return
        }
        guard zoneNames.contains(zone) else {
            reject(session: request.session, id: id, reason: .zoneNotFound)
            return
        }
        guard active == nil else {
            reject(session: request.session, id: id, reason: .busy)
            return
        }

        let token = runtime.motionStopCounter.read()
        guard request.stopToken == token else {
            reject(session: request.session, id: id, reason: .staleAfterStop)
            return
        }
        let operation = Operation(session: request.session, seq: request.seq, id: id, token: token)
        active = operation

        do {
            _ = try await runtime.look(zone: zone, leaseSeconds: 30, stopToken: token)
            finish(operation, error: nil)
        } catch {
            finish(operation, error: error)
        }
    }

    private func finish(_ operation: Operation, error: (any Error)?) {
        stopCounter.withValue { current in
            observeCounterChange(current: current)
            guard active == operation else { return }
            active = nil
            if let error {
                reject(session: operation.session, id: operation.id, reason: rejection(for: error))
            } else {
                emit(WatchEventEnvelope(session: operation.session,
                    event: .arrived(operationID: operation.id, stopCounter: operation.token)))
            }
        }
    }

    private func sendStatus() async {
        observeCounterChange()
        let records = await runtime.zones()
        let zones = records.filter { !$0.forbidden }.map(\.name).sorted()
        zoneNames = Set(zones)
        let status = try? await runtime.status()
        stopCounter.withValue { current in
            observeCounterChange(current: current)
            output.yield(.status(WatchStatus(
                stopToken: current, connected: status?.connected ?? false,
                batteryPercent: status?.battery?.percent,
                pose: status?.pose.map { WatchPose(yaw: $0.yaw, pitch: $0.pitch, roll: $0.roll) },
                zoneNames: zones, terminalEvent: latestTerminalEvent
            )))
        }
    }

    private func observeCounterChange() {
        stopCounter.withValue { observeCounterChange(current: $0) }
    }

    private func observeCounterChange(current: UInt64) {
        guard current != observedStopCounter else { return }
        observedStopCounter = current
        quietUntil = clock.now().addingTimeInterval(2)
        latestTerminalEvent = PhoneWatchEventPublication.correctedTerminal(latestTerminalEvent, current: current)
        guard let old = active else { return }
        active = nil
        emit(WatchEventEnvelope(
            session: old.session,
            event: .stopped(operationID: old.id, stopCounter: old.token)
        ))
    }

    private func reject(session: UUID?, id: UUID, reason: WatchRejection) {
        emit(WatchEventEnvelope(
            session: session,
            event: .rejected(operationID: id, reason: reason)
        ))
    }

    private func emit(_ envelope: WatchEventEnvelope, remember: Bool = true) {
        if remember {
            latestTerminalEvent = envelope
            terminalRevision += 1
        }
        output.yield(.event(envelope))
    }

    private func rejection(for error: any Error) -> WatchRejection {
        if let error = error as? NavigationError {
            switch error {
            case .busy: return .busy
            case .referenceRequired: return .referenceRequired
            case .stalePose: return .stalePose
            case .unsafePath: return .unsafePath
            case .timeout: return .timeout
            case .interrupted: return .interrupted
            }
        }
        if let error = error as? SafetyViolation {
            switch error {
            case .unknownZone(_): return .zoneNotFound
            case .poseUnavailable: return .disconnected
            case .busy(_): return .busy
            case .speedTooHigh(_, _), .forbiddenZone(_), .outsideZone(_), .invalidValue: return .policyRejected
            case .noLease, .leaseExpired, .leaseTooLong(_), .invalidDuration, .unsupported(_): return .failed
            }
        }
        return .failed
    }
}
