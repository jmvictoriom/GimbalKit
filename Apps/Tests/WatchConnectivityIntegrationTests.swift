import Foundation
import Observation
import Testing
import GimbalHostSupport
import GimbalKit
import GimbalKitMCP
import GimbalWatchKit

@MainActor
private final class PhoneTransportProbe: PhoneWatchTransport {
    var isReachable = true
    var events: [WatchEventEnvelope] = []
    var statuses: [WatchStatus] = []
    var onSend: ((WatchEventEnvelope) -> Void)?
    func activate(bridge: PhoneWatchBridge) {}
    func sendEvent(_ event: WatchEventEnvelope) { onSend?(event); events.append(event) }
    func updateContext(_ status: WatchStatus) { statuses.append(status) }
}

@MainActor
private final class WatchTransportProbe: WatchMessageTransport {
    var isReachable = true
    var requests: [WatchRequest] = []
    var failures: [@Sendable (String) -> Void] = []
    func activate(client: WatchConnectivityClient) {}
    func send(_ request: WatchRequest, onFailure: @escaping @Sendable (String) -> Void) {
        requests.append(request)
        failures.append(onFailure)
    }
}

private actor BridgeRuntimeProbe: PhoneWatchRuntime {
    nonisolated let motionStopCounter = MotionStopCounter()
    func humanStop() { motionStopCounter.increment() }
    func look(zone: String, leaseSeconds: Double, stopToken: UInt64?) throws -> GimbalLookResult {
        throw NavigationError.referenceRequired
    }
    func status() -> GimbalStatus {
        GimbalStatus(connected: false, referenceReady: false, battery: nil, pose: nil, lease: nil)
    }
    func zones() -> [ZoneRecord] { [] }
}

private func appWatchStatus(token: UInt64, terminal: WatchEventEnvelope? = nil) -> WatchStatus {
    WatchStatus(stopToken: token, connected: true, batteryPercent: nil, pose: nil,
                zoneNames: ["mesa"], terminalEvent: terminal)
}

@Suite @MainActor
struct WatchConnectivityIntegrationTests {
    @Test func phoneBridgeSerializesActualTransportSendWithStopIncrement() async throws {
        let runtime = BridgeRuntimeProbe()
        let service = PhoneWatchService(runtime: runtime)
        let transport = PhoneTransportProbe()
        let bridge = PhoneWatchBridge(service: service, transport: transport)
        let order = AppPublicationOrder()
        let started = DispatchSemaphore(value: 0)
        let (finished, done) = AsyncStream.makeStream(of: Void.self)
        let counter = runtime.motionStopCounter
        transport.onSend = { _ in
            Thread.detachNewThread {
                started.signal()
                counter.increment()
                order.append("stop")
                done.yield(())
                done.finish()
            }
            started.wait()
            order.append("send")
        }
        await bridge.publish(.event(WatchEventEnvelope(session: nil,
            event: .arrived(operationID: UUID(), stopCounter: 0))))
        try #require(transport.events.count == 1)
        for await _ in finished { break }
        #expect(order.values == ["send", "stop"])
        await service.shutdown()
    }

    @Test func phoneBridgeCorrectsQueuedArrivalAndContextAfterExternalStop() async {
        let runtime = BridgeRuntimeProbe()
        let service = PhoneWatchService(runtime: runtime)
        let transport = PhoneTransportProbe()
        let bridge = PhoneWatchBridge(service: service, transport: transport)
        let id = UUID()
        let arrived = WatchEventEnvelope(session: UUID(), event: .arrived(operationID: id, stopCounter: 0))
        await runtime.humanStop()
        await bridge.publish(.event(arrived))
        await bridge.publish(.status(appWatchStatus(token: 0, terminal: arrived)))
        #expect(transport.events.last?.event == .stopped(operationID: id, stopCounter: 0))
        #expect(transport.statuses.last?.stopToken == 1)
        #expect(transport.statuses.last?.terminalEvent?.event == .stopped(operationID: id, stopCounter: 0))
        await service.shutdown()
    }

    @Test func phoneBridgeDiscardsStaleImmediateStopButPreservesItInContext() async {
        let runtime = BridgeRuntimeProbe()
        let service = PhoneWatchService(runtime: runtime)
        let transport = PhoneTransportProbe()
        let bridge = PhoneWatchBridge(service: service, transport: transport)
        let stopped = WatchEventEnvelope(session: UUID(), event: .stopped(operationID: UUID(), stopCounter: 0))
        await runtime.humanStop()
        await bridge.publish(.event(stopped))
        await bridge.publish(.status(appWatchStatus(token: 0, terminal: stopped)))
        #expect(transport.events.isEmpty)
        #expect(transport.statuses.last?.terminalEvent == stopped)
        #expect(transport.statuses.last?.stopToken == 1)
        await service.shutdown()
    }

    @Test func watchUsesNewestTokenAndDeduplicatesTerminalAcrossChannels() throws {
        let transport = WatchTransportProbe()
        let client = WatchConnectivityClient(transport: transport)
        client.receive(appWatchStatus(token: 2))
        client.look(zone: "mesa")
        let request = try #require(transport.requests.last)
        let id = try #require(request.operationID)
        #expect(request.stopToken == 2)
        client.receive(appWatchStatus(token: 3))
        client.receive(WatchEventEnvelope(session: request.session, event: .arrived(operationID: id, stopCounter: 2)))
        #expect(client.lastEvent == nil)
        #expect(client.currentOperationID == id)
        let stopped = WatchEventEnvelope(session: request.session, event: .stopped(operationID: id, stopCounter: 2))
        client.receive(appWatchStatus(token: 3, terminal: stopped))
        #expect(client.lastEvent == stopped.event)
        #expect(client.currentOperationID == nil)
        client.receive(stopped)
        #expect(client.lastEvent == stopped.event)
        client.receive(appWatchStatus(token: 1))
        client.look(zone: "mesa")
        #expect(transport.requests.last?.stopToken == 3)
    }

    @Test func watchDeliveryFailureClearsOnlyMatchingOperationAndReportsStopFailure() throws {
        let transport = WatchTransportProbe()
        let client = WatchConnectivityClient(transport: transport)
        client.receive(appWatchStatus(token: 0))
        client.look(zone: "mesa")
        let old = try #require(client.currentOperationID)
        client.stop()
        let current = try #require(client.currentOperationID)
        client.deliveryFailed("Entrega antigua fallida", operationID: old)
        #expect(client.currentOperationID == current)
        #expect(client.connectionError == nil)
        client.deliveryFailed("No se pudo entregar PARAR", operationID: current)
        #expect(client.currentOperationID == nil)
        #expect(client.connectionError == "No se pudo entregar PARAR")
    }

    @Test func watchUnreachableSendClearsPendingOperation() {
        let transport = WatchTransportProbe()
        transport.isReachable = false
        let client = WatchConnectivityClient(transport: transport)
        client.stop()
        #expect(client.currentOperationID == nil)
        #expect(client.connectionError == "iPhone fuera de alcance")
        #expect(transport.requests.isEmpty)
    }

    @Test func watchHandlesAsynchronousDeliveryFailureAfterReachabilityGuard() async throws {
        let transport = WatchTransportProbe()
        let client = WatchConnectivityClient(transport: transport)
        client.receive(appWatchStatus(token: 0))
        client.look(zone: "mesa")
        let id = try #require(client.currentOperationID)
        let failure = try #require(transport.failures.last)
        let (changes, changed) = AsyncStream.makeStream(of: Void.self)
        withObservationTracking {
            _ = client.connectionError
        } onChange: {
            changed.yield(())
            changed.finish()
        }
        failure("Alcance perdido durante la entrega")
        for await _ in changes { break }
        #expect(client.currentOperationID == nil)
        #expect(client.connectionError == "Alcance perdido durante la entrega")
        #expect(client.lastEvent == .rejected(operationID: id, reason: .failed))
    }
}

private final class AppPublicationOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var values: [String] { lock.withLock { entries } }
}
