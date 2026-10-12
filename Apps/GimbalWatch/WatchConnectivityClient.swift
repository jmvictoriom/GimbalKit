import Foundation
import Observation
import GimbalWatchKit

@MainActor
protocol WatchMessageTransport: AnyObject {
    var isReachable: Bool { get }
    func activate(client: WatchConnectivityClient)
    func send(_ request: WatchRequest, onFailure: @escaping @Sendable (String) -> Void)
}

@MainActor @Observable
final class WatchConnectivityClient {
    @ObservationIgnored private let transport: any WatchMessageTransport
    @ObservationIgnored private var activated = false
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var sequence: UInt64 = 0
    private var operationState = WatchOperationState()
    private var latestStopToken: UInt64?
    private(set) var reachable = false
    private(set) var status: WatchStatus?
    private(set) var lastEvent: WatchEvent?
    private(set) var connectionError: String?
    var currentOperationID: UUID? { operationState.currentOperationID }

    init(transport: any WatchMessageTransport) { self.transport = transport }

    #if os(watchOS)
    convenience init() { self.init(transport: WatchMessageSession()) }
    #endif

    func activate() {
        guard !activated else { return }
        activated = true
        transport.activate(client: self)
    }

    func requestStatus() {
        send(WatchRequest(session: sessionID, seq: nextSequence(), operationID: nil,
                          stopToken: nil, command: .status))
    }

    func stop() {
        let id = UUID()
        operationState.begin(id)
        send(WatchRequest(session: sessionID, seq: nextSequence(), operationID: id,
                          stopToken: nil, command: .stop))
    }

    func look(zone: String) {
        guard let token = latestStopToken else {
            requestStatus()
            return
        }
        let id = UUID()
        operationState.begin(id)
        send(WatchRequest(session: sessionID, seq: nextSequence(), operationID: id,
                          stopToken: token, command: .look(zone: zone)))
    }

    private func nextSequence() -> UInt64 {
        precondition(sequence < UInt64.max, "Secuencia Watch agotada; reinicia la sesión")
        sequence += 1
        return sequence
    }

    private func send(_ request: WatchRequest) {
        guard transport.isReachable else {
            reachable = false
            deliveryFailed("iPhone fuera de alcance", operationID: request.operationID)
            return
        }
        connectionError = nil
        let id = request.operationID
        transport.send(request) { [weak self] message in
            Task { @MainActor [weak self] in
                self?.deliveryFailed(message, operationID: id)
            }
        }
    }

    func deliveryFailed(_ message: String, operationID: UUID?) {
        if let operationID {
            guard operationState.currentOperationID == operationID else { return }
            lastEvent = operationState.apply(.rejected(operationID: operationID, reason: .failed))
        }
        connectionError = message
    }

    func receive(_ envelope: WatchEventEnvelope) {
        guard envelope.session == nil || envelope.session == sessionID else { return }
        switch envelope.event {
        case let .arrived(_, token), let .stopped(_, token): observeStopToken(token)
        case .rejected: break
        }
        guard let event = operationState.apply(envelope.event) else { return }
        lastEvent = event
    }

    func receive(_ status: WatchStatus) {
        // Un contexto antiguo no puede degradar el token usado por la siguiente mirada.
        guard status.stopToken >= (latestStopToken ?? 0) else { return }
        observeStopToken(status.stopToken)
        self.status = status
        if let terminalEvent = status.terminalEvent { receive(terminalEvent) }
    }

    private func observeStopToken(_ token: UInt64) {
        latestStopToken = max(latestStopToken ?? 0, token)
        operationState.observeStopToken(token)
    }

    func setReachable(_ reachable: Bool) {
        self.reachable = reachable
        if reachable { requestStatus() }
    }

    func activationCompleted(reachable: Bool, errorMessage: String?) {
        connectionError = errorMessage
        setReachable(reachable)
    }
}

#if os(watchOS)
@preconcurrency import WatchConnectivity

/// Único propietario de WCSession en el reloj; nunca importa el runtime o BLE.
@MainActor
private final class WatchMessageSession: NSObject, WatchMessageTransport, WCSessionDelegate {
    private let session = WCSession.default
    private weak var client: WatchConnectivityClient?

    var isReachable: Bool { session.isReachable }

    func activate(client: WatchConnectivityClient) {
        guard WCSession.isSupported() else { return }
        self.client = client
        session.delegate = self
        session.activate()
    }

    func send(_ request: WatchRequest, onFailure: @escaping @Sendable (String) -> Void) {
        session.sendMessage(WatchMessageCodec.encodeRequest(request), replyHandler: nil) { error in
            onFailure(error.localizedDescription)
        }
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        let reachable = session.isReachable
        let errorMessage = error?.localizedDescription
        let status = try? WatchMessageCodec.decodeStatus(session.receivedApplicationContext)
        Task { @MainActor [weak self] in
            guard let client = self?.client else { return }
            if let status { client.receive(status) }
            client.activationCompleted(reachable: reachable, errorMessage: errorMessage)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in self?.client?.setReachable(reachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let status = try? WatchMessageCodec.decodeStatus(applicationContext)
        Task { @MainActor [weak self] in if let status { self?.client?.receive(status) } }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let envelope = try? WatchMessageCodec.decodeEvent(message)
        Task { @MainActor [weak self] in if let envelope { self?.client?.receive(envelope) } }
    }
}
#endif
