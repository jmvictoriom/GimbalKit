import Foundation
import GimbalHostSupport
import GimbalWatchKit

@MainActor
protocol PhoneWatchTransport: AnyObject {
    var isReachable: Bool { get }
    func activate(bridge: PhoneWatchBridge)
    func sendEvent(_ event: WatchEventEnvelope)
    func updateContext(_ status: WatchStatus) throws
}

@MainActor
final class PhoneWatchBridge {
    private let service: PhoneWatchService
    private let transport: any PhoneWatchTransport
    private var activated = false
    private var outputTask: Task<Void, Never>?

    init(service: PhoneWatchService, transport: any PhoneWatchTransport) {
        self.service = service
        self.transport = transport
    }

    #if os(iOS)
    convenience init(service: PhoneWatchService) {
        self.init(service: service, transport: PhoneWatchSession())
    }
    #endif

    func activate() {
        guard !activated else { return }
        activated = true
        outputTask = Task { [weak self, service] in
            for await output in service.outputs {
                guard let self else { return }
                await self.publish(output)
            }
        }
        transport.activate(bridge: self)
    }

    func refreshStatus() async { await service.refreshStatus() }

    func receive(_ request: WatchRequest) async { await service.receive(request) }

    func rejectMalformed(session: UUID?, operationID: UUID?) async {
        await service.rejectMalformed(session: session, operationID: operationID)
    }

    func setReachable(_ reachable: Bool) async {
        await service.setReachable(reachable)
        await service.refreshStatus()
    }

    func publish(_ output: PhoneWatchOutput) async {
        // El envío real, incluido application context, queda bajo el lock de STOP.
        // No introducir un await ni acceder al contador dentro del closure.
        let published = PhoneWatchEventPublication.publish(output, stopCounter: service.stopCounter) { prepared in
            switch prepared {
            case let .event(event):
                if transport.isReachable { transport.sendEvent(event) }
            case let .status(status):
                try? transport.updateContext(status)
            }
        }

        switch (output, published) {
        case let (.event(original), .event(correction)) where original != correction:
            await service.replaceLatestTerminalEvent(correction, replacing: original)
        case let (.status(original), .status(correction)):
            if let oldTerminal = original.terminalEvent, let newTerminal = correction.terminalEvent,
               oldTerminal != newTerminal {
                await service.replaceLatestTerminalEvent(newTerminal, replacing: oldTerminal)
            }
        default: break
        }
        if case .event = output { await service.refreshStatus() }
    }
}

#if os(iOS)
@preconcurrency import WatchConnectivity

/// Único propietario de WCSession en el iPhone. Los callbacks cruzan solo DTO.
@MainActor
private final class PhoneWatchSession: NSObject, PhoneWatchTransport, WCSessionDelegate {
    private let session = WCSession.default
    private weak var bridge: PhoneWatchBridge?

    var isReachable: Bool { session.isReachable }

    func activate(bridge: PhoneWatchBridge) {
        guard WCSession.isSupported() else { return }
        self.bridge = bridge
        session.delegate = self
        session.activate()
        let reachable = session.isReachable
        Task { await bridge.setReachable(reachable) }
    }

    func sendEvent(_ event: WatchEventEnvelope) {
        session.sendMessage(WatchMessageCodec.encodeEvent(event), replyHandler: nil, errorHandler: nil)
    }

    func updateContext(_ status: WatchStatus) throws {
        guard session.activationState == .activated else { return }
        try session.updateApplicationContext(WatchMessageCodec.encodeStatus(status))
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let request = try? WatchMessageCodec.decodeRequest(message)
        let sessionID = (message["session"] as? String).flatMap(UUID.init(uuidString:))
        let operationID = (message["operationID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak self] in
            guard let bridge = self?.bridge else { return }
            if let request {
                await bridge.receive(request)
            } else {
                await bridge.rejectMalformed(session: sessionID, operationID: operationID)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in await self?.bridge?.setReachable(reachable) }
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in await self?.bridge?.setReachable(reachable) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in await self?.bridge?.setReachable(reachable) }
    }
}
#endif
