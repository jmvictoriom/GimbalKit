import Foundation
import Network
import GimbalKit

@MainActor public protocol MCPServerControl: AnyObject, Sendable {
    var onUnexpectedTermination: (@MainActor @Sendable () -> Void)? { get set }
    func start(port: UInt16) async throws -> UInt16
    func stop() async
}
@MainActor public final class HTTPServer: MCPServerControl {
    private let service: any GimbalService
    private let dispatcher: MCPDispatcher
    private let token: String
    private let clock: RuntimeClock
    private let queue = DispatchQueue(label: "gimbalkit.http")
    private var listener: NWListener?
    private var readiness: CheckedContinuation<UInt16, any Error>?
    private(set) var generation = UUID()
    private var ready = false
    private var peers: [UUID: HTTPPeer] = [:]
    private var shutdown: Task<Void, Never>?
    public var onUnexpectedTermination: (@MainActor @Sendable () -> Void)?
    var activePeerCount: Int { peers.values.filter { !$0.closed }.count }

    public init(service: any GimbalService, token: String, clock: RuntimeClock = .live) {
        self.service = service
        dispatcher = MCPDispatcher(service: service); self.token = token; self.clock = clock
    }
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        guard listener == nil, shutdown == nil, !ready else { throw HTTPFailure(409) }
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let created = try NWListener(using: parameters)
        listener = created
        let current = UUID(); generation = current
        created.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                await self?.listenerStateChanged(state, port: created.port?.rawValue, generation: current)
            }
        }
        created.newConnectionHandler = { @Sendable [weak self] connection in
            Task { @MainActor in
                guard let self, let port = created.port?.rawValue,
                      let peer = self.reservePeer(connection: connection, port: port, generation: current) else {
                    connection.cancel(); return
                }
                peer.start(queue: self.queue)
            }
        }
        do {
            let port = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    readiness = continuation
                    created.start(queue: queue)
                }
            } onCancel: {
                Task { @MainActor [weak self] in await self?.stop(generation: current) }
            }
            try Task.checkCancellation()
            return port
        } catch {
            await stop(generation: current)
            throw error
        }
    }
    // Shared by the Network callbacks and deterministic lifecycle tests.
    func listenerStateChanged(_ state: NWListener.State, port: UInt16?, generation current: UUID) async {
        guard generation == current else { return }
        switch state {
        case .ready:
            guard let port else {
                finish(.failure(HTTPFailure(500)))
                await stop(generation: current)
                return
            }
            ready = true
            finish(.success(port))
        case let .failed(error):
            finish(.failure(error))
            await beginShutdown(unexpected: ready).value
        case .cancelled:
            finish(.failure(CancellationError()))
            await beginShutdown(unexpected: ready).value
        default: break
        }
    }
    func reservePeer(connection: NWConnection, port: UInt16, generation current: UUID) -> HTTPPeer? {
        guard generation == current, ready, shutdown == nil, peers.count < 16 else {
            connection.cancel(); return nil
        }
        let id = UUID()
        let peer = HTTPPeer(connection: connection, gate: HTTPGate(port: port, token: token),
                            dispatcher: dispatcher, clock: clock, onClose: { [weak self] in self?.peers[id] = nil })
        peers[id] = peer
        return peer
    }
    private func finish(_ result: Result<UInt16, any Error>) {
        let continuation = readiness; readiness = nil
        continuation?.resume(with: result)
    }
    func stop(generation current: UUID) async {
        guard generation == current else { return }
        await stop()
    }
    public func stop() async { await beginShutdown(unexpected: false).value }
    private func beginShutdown(unexpected: Bool) -> Task<Void, Never> {
        if let shutdown { return shutdown }
        generation = UUID()
        ready = false
        finish(.failure(CancellationError()))
        listener?.cancel(); listener = nil
        let current = Array(peers.values)
        for peer in current { peer.close() }
        // Keep disconnected peers until their cancellation cleanup completes.
        // Starting another generation is blocked until revocation finishes.
        let notification = onUnexpectedTermination
        let task = Task { @MainActor in
            for peer in current { await peer.waitUntilClosed() }
            if unexpected {
                try? await service.stop()
                notification?()
            }
            shutdown = nil
        }
        shutdown = task
        return task
    }
}

@MainActor final class HTTPPeer {
    private let connection: NWConnection
    private let gate: HTTPGate
    private let dispatcher: MCPDispatcher
    private let clock: RuntimeClock
    private let onClose: @MainActor () -> Void
    private var parser = HTTPParser()
    private var deadline: Task<Void, Never>?
    private(set) var work: Task<Void, Never>?
    private(set) var closed = false
    private var cleanup: Task<Void, Never>?
    private var responding = false
    init(connection: NWConnection, gate: HTTPGate, dispatcher: MCPDispatcher,
         clock: RuntimeClock, onClose: @escaping @MainActor () -> Void) {
        self.connection = connection; self.gate = gate; self.dispatcher = dispatcher
        self.clock = clock; self.onClose = onClose
    }
    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: queue)
        beginReadDeadline()
        receive()
    }
    func beginReadDeadline() {
        deadline = Task { [weak self] in
            guard let self else { return }
            do { try await clock.sleep(5); if !Task.isCancelled { send(RPCReply(status: 408, body: Data())) } }
            catch { return }
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { @Sendable [weak self] data, _, complete, error in
            Task { @MainActor in self?.received(data: data, complete: complete, failed: error != nil) }
        }
    }
    func received(data: Data?, complete: Bool, failed: Bool) {
        guard !closed, !responding else { return }
        if failed { close(); return }
        do {
            if let request = try parser.feed(data ?? Data()) {
                deadline?.cancel()
                try gate.validate(request)
                // En este transporte un EOF cancela la operación; no admitir half-close con movimiento.
                guard !complete else { close(); return }
                work = Task { [weak self] in
                    guard let self else { return }
                    let reply = await dispatcher.respond(to: request.body)
                    guard !Task.isCancelled, !closed else { return }
                    work = nil
                    send(reply)
                }
                watchDisconnect()
            } else if complete { send(RPCReply(status: 400, body: Data())) }
            else { receive() }
        } catch let error as HTTPFailure { send(RPCReply(status: error.status, body: Data())) }
        catch { send(RPCReply(status: 400, body: Data())) }
    }
    private func watchDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { @Sendable [weak self] data, _, complete, error in
            Task { @MainActor in self?.disconnected(data: data, complete: complete, failed: error != nil) }
        }
    }
    func disconnected(data: Data?, complete: Bool, failed: Bool) {
        guard !closed, !responding else { return }
        if complete || failed || !(data?.isEmpty ?? true) { close() }
        else { watchDisconnect() }
    }
    private func send(_ reply: RPCReply) {
        guard !closed, !responding else { return }
        responding = true; deadline?.cancel()
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                       404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout",
                       411: "Length Required", 413: "Content Too Large", 415: "Unsupported Media Type", 431: "Request Header Fields Too Large"]
        var text = "HTTP/1.1 \(reply.status) \(reasons[reply.status] ?? "Error")\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n"
        if !reply.body.isEmpty { text += "Content-Type: application/json\r\n" }
        if reply.status == 401 { text += "WWW-Authenticate: Bearer\r\n" }
        if reply.status == 405 { text += "Allow: POST\r\n" }
        // Sin Access-Control-Allow-Origin: no habilitar CORS para páginas web.
        text += "\r\n"
        connection.send(content: Data(text.utf8) + reply.body, completion: .contentProcessed { @Sendable [weak self] _ in
            Task { @MainActor in self?.close() }
        })
    }
    func close() {
        guard !closed else { return }
        closed = true; deadline?.cancel(); work?.cancel()
        let reading = deadline, running = work
        connection.cancel()
        cleanup = Task { @MainActor in
            await reading?.value
            await running?.value
            deadline = nil; work = nil
            onClose()
        }
    }
    func waitUntilClosed() async { await cleanup?.value }
}
