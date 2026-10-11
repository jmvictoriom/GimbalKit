import Foundation
import Network
import Testing
import GimbalKit
@testable import GimbalKitMCP

func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 3
    configuration.connectionProxyDictionary = [:]
    return URLSession(configuration: configuration)
}
func post(port: UInt16, token: String = testToken, origin: String? = nil,
          body: String = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) -> URLRequest {
    var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    r.httpMethod = "POST"; r.httpBody = Data(body.utf8)
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    if let origin { r.setValue(origin, forHTTPHeaderField: "Origin") }
    return r
}

@MainActor @Test func httpLoopbackUsesEphemeralPortAndChecksCredentialsAndOrigin() async throws {
    let server = HTTPServer(service: FakeService(), token: testToken)
    let port = try await server.start(port: 0)
    #expect(port > 0)
    let client = session()
    do {
        for (request, expected) in [(post(port: port), 200), (post(port: port, token: "bad"), 401),
                                     (post(port: port, origin: "http://evil.test"), 403),
                                     (post(port: port, body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), 202)] {
            let (_, response) = try await client.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == expected)
        }
        var nonBound = post(port: port)
        nonBound.url = URL(string: "http://127.0.0.2:\(port)/mcp")!
        await #expect(throws: URLError.self) { try await client.data(for: nonBound) }
    } catch { await server.stop(); client.invalidateAndCancel(); throw error }
    await server.stop(); client.invalidateAndCancel()
}

actor ReadDeadline {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private(set) var waiting = false
    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }
    func sleep() async throws {
        waiting = true
        for await _ in stream { break }
        try Task.checkCancellation()
    }
    func fire() { continuation.yield(()) }
}

@MainActor @Test func incompleteHTTPRequestTimesOutWithoutRealSleep() async throws {
    let gate = ReadDeadline()
    let server = HTTPServer(service: FakeService(), token: testToken,
                            clock: RuntimeClock(now: { Date() }, sleep: { _ in try await gate.sleep() }))
    let port = try await server.start(port: 0)
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.start(queue: DispatchQueue(label: "gimbal.test.raw"))
    let response = Task { () throws -> Data in
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data("POST /mcp HTTP/1.1\r\nHost: ".utf8), completion: .contentProcessed { @Sendable error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
        var buffer = Data()
        while buffer.count < 4096 {
            let part: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096 - buffer.count) { @Sendable data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
            if part.isEmpty { return buffer }
            buffer.append(part)
            if buffer.range(of: Data([13, 10])) != nil { return buffer }
        }
        throw HTTPFailure(431)
    }
    while !(await gate.waiting) { await Task.yield() }
    await gate.fire()
    do { #expect(String(decoding: try await response.value, as: UTF8.self).hasPrefix("HTTP/1.1 408")) }
    catch { connection.cancel(); await server.stop(); throw error }
    connection.cancel(); await server.stop()
}

@MainActor @Test(arguments: [false, true])
func unexpectedListenerTerminationRevokesServiceAndNotifiesHost(cancelled: Bool) async {
    let service = FakeService()
    let server = HTTPServer(service: service, token: testToken)
    var notifications = 0
    let control: any MCPServerControl = server
    control.onUnexpectedTermination = { notifications += 1 }
    let current = server.generation
    await server.listenerStateChanged(.ready, port: 12345, generation: current)
    await server.listenerStateChanged(cancelled ? .cancelled : .failed(.posix(.ECONNRESET)),
                                      port: 12345, generation: current)
    #expect(notifications == 1)
    #expect(await service.stops == 1)
    await server.listenerStateChanged(.cancelled, port: 12345, generation: current)
    #expect(notifications == 1)
    await server.stop()
}

@MainActor @Test func staleListenerTerminationCannotRevokeNewGeneration() async {
    let service = FakeService()
    let server = HTTPServer(service: service, token: testToken)
    let old = server.generation
    await server.listenerStateChanged(.ready, port: 12345, generation: old)
    await server.stop()
    let current = server.generation
    await server.listenerStateChanged(.ready, port: 12345, generation: current)
    await server.listenerStateChanged(.failed(.posix(.ECONNRESET)), port: 12345, generation: old)
    await server.stop(generation: old)
    #expect(await service.stops == 0)
    let connection = NWConnection(host: "127.0.0.1", port: 12345, using: .tcp)
    #expect(server.reservePeer(connection: connection, port: 12345, generation: current) != nil)
    await server.stop()
}

actor SuspendedHTTPService: GimbalService {
    private(set) var entered = false
    private(set) var cancelling = false
    private(set) var cleaned = false
    private(set) var stops = 0
    private var release: CheckedContinuation<Void, Never>?
    func status() -> GimbalStatus {
        GimbalStatus(connected: true, referenceReady: true, battery: nil, pose: Pose(), lease: nil)
    }
    func zones() -> [ZoneRecord] { [] }
    func stop() { stops += 1 }
    func look(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult {
        entered = true
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        defer { continuation.finish() }
        for await _ in stream { }
        cancelling = Task.isCancelled
        await withCheckedContinuation { release = $0 }
        cleaned = true
        throw CancellationError()
    }
    func finishCleanup() { release?.resume(); release = nil }
}

func rawRequest(port: UInt16, body: String) -> Data {
    Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: \(body.utf8.count)\r\nContent-Type: application/json\r\nAccept: application/json\r\nAuthorization: Bearer \(testToken)\r\n\r\n\(body)".utf8)
}
let suspendedLook = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"gimbal_look","arguments":{"zone":"mesa"}}}"#

@MainActor @Test(arguments: ["stop", "disconnect", "pipeline", "failed", "cancelled"])
func serverShutdownWaitsForSuspendedToolCleanup(trigger: String) async throws {
    let service = SuspendedHTTPService()
    let server = HTTPServer(service: service, token: testToken)
    let current = server.generation
    await server.listenerStateChanged(.ready, port: 12345, generation: current)
    let connection = NWConnection(host: "127.0.0.1", port: 12345, using: .tcp)
    let peer = try #require(server.reservePeer(connection: connection, port: 12345, generation: current))
    peer.received(data: rawRequest(port: 12345, body: suspendedLook), complete: false, failed: false)
    while !(await service.entered) { await Task.yield() }
    if trigger == "disconnect" { peer.disconnected(data: nil, complete: true, failed: false) }
    if trigger == "pipeline" { peer.disconnected(data: Data([80]), complete: false, failed: false) }
    var returned = false
    let shutdown = Task { @MainActor in
        if trigger == "failed" || trigger == "cancelled" {
            await server.listenerStateChanged(trigger == "failed" ? .failed(.posix(.ECONNRESET)) : .cancelled,
                                              port: 12345, generation: current)
        } else { await server.stop() }
        returned = true
    }
    while !(await service.cancelling) { await Task.yield() }
    #expect(!returned)
    #expect(!(await service.cleaned))
    await #expect(throws: HTTPFailure(409)) { try await server.start(port: 0) }
    await service.finishCleanup()
    await shutdown.value
    #expect(returned)
    #expect(await service.cleaned)
    #expect(await service.stops == (trigger == "failed" || trigger == "cancelled" ? 1 : 0))
}

@MainActor @Test func admissionReservesOnlySixteenPeersBeforeAllocatingTheNext() async throws {
    let server = HTTPServer(service: FakeService(), token: testToken)
    let current = server.generation
    await server.listenerStateChanged(.ready, port: 12345, generation: current)
    var accepted: [HTTPPeer] = []
    for _ in 0..<16 {
        let connection = NWConnection(host: "127.0.0.1", port: 12345, using: .tcp)
        accepted.append(try #require(server.reservePeer(connection: connection, port: 12345, generation: current)))
    }
    let extra = NWConnection(host: "127.0.0.1", port: 12345, using: .tcp)
    #expect(server.reservePeer(connection: extra, port: 12345, generation: current) == nil)
    #expect(accepted.allSatisfy { !$0.closed })
    await server.stop()
    #expect(accepted.allSatisfy { $0.closed })
}

@MainActor @Test func seventeenthRealLoopbackPeerIsClosedWhileSixteenRemainUsable() async throws {
    let deadline = QuietReadClock()
    let server = HTTPServer(service: FakeService(), token: testToken,
                            clock: RuntimeClock(now: { Date() }, sleep: { _ in try await deadline.sleep() }))
    let port = try await server.start(port: 0)
    var connections: [NWConnection] = []
    do {
        for _ in 0..<16 {
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connections.append(connection)
            connection.start(queue: DispatchQueue(label: "gimbal.test.cap"))
            try await sendRaw(connection, data: Data("POST ".utf8))
            while server.activePeerCount < connections.count { await Task.yield() }
        }
        let extra = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connections.append(extra)
        extra.start(queue: DispatchQueue(label: "gimbal.test.cap.extra"))
        let ended = try? await receiveRaw(extra)
        #expect(ended == nil || ended?.isEmpty == true)
        #expect(server.activePeerCount == 16)
        let request = rawRequest(port: port, body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        for connection in connections.dropLast() {
            try await sendRaw(connection, data: Data(request.dropFirst(5)))
            #expect(String(decoding: try await receiveStatusLine(connection), as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        }
    } catch {
        connections.forEach { $0.cancel() }; await server.stop(); throw error
    }
    connections.forEach { $0.cancel() }; await server.stop()
}

func sendRaw(_ connection: NWConnection, data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        connection.send(content: data, completion: .contentProcessed { @Sendable error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        })
    }
}
func receiveRaw(_ connection: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { @Sendable data, _, _, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: data ?? Data()) }
        }
    }
}

@MainActor @Test func disconnectedPeerRetainsItsAdmissionSlotUntilToolCleanupCompletes() async throws {
    let service = SuspendedHTTPService()
    let server = HTTPServer(service: service, token: testToken)
    let current = server.generation
    await server.listenerStateChanged(.ready, port: 12345, generation: current)
    let first = NWConnection(host: "127.0.0.1", port: 12345, using: .tcp)
    let peer = try #require(server.reservePeer(connection: first, port: 12345, generation: current))
    peer.received(data: rawRequest(port: 12345, body: suspendedLook), complete: false, failed: false)
    while !(await service.entered) { await Task.yield() }
    peer.disconnected(data: nil, complete: true, failed: false)
    while !(await service.cancelling) { await Task.yield() }
    for _ in 0..<15 {
        let connection = NWConnection(host: "127.0.0.1", port: 12345, using: .tcp)
        #expect(server.reservePeer(connection: connection, port: 12345, generation: current) != nil)
    }
    let extra = NWConnection(host: "127.0.0.1", port: 12345, using: .tcp)
    #expect(server.reservePeer(connection: extra, port: 12345, generation: current) == nil)
    await service.finishCleanup()
    await peer.waitUntilClosed()
    let replacement = NWConnection(host: "127.0.0.1", port: 12345, using: .tcp)
    #expect(server.reservePeer(connection: replacement, port: 12345, generation: current) != nil)
    await server.stop()
}

func receiveStatusLine(_ connection: NWConnection) async throws -> Data {
    var buffer = Data()
    while buffer.count < 4096 {
        let part = try await receiveRaw(connection)
        if part.isEmpty { break }
        buffer.append(part)
        if buffer.range(of: Data([13, 10])) != nil { break }
    }
    return buffer
}

actor ControlledReadClock {
    private(set) var durations: [Double] = []
    private(set) var cancelling = false
    private(set) var cleaned = false
    private var release: CheckedContinuation<Void, Never>?
    func sleep(_ seconds: Double) async throws {
        durations.append(seconds)
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        defer { continuation.finish() }
        for await _ in stream { }
        cancelling = Task.isCancelled
        await withCheckedContinuation { release = $0 }
        cleaned = true
        try Task.checkCancellation()
    }
    func finishCleanup() { release?.resume(); release = nil }
}

@MainActor @Test func completedRequestRetainsReadDeadlineUntilCancellationCleanupFinishes() async throws {
    let clock = ControlledReadClock()
    let server = HTTPServer(service: FakeService(), token: testToken,
                            clock: RuntimeClock(now: { Date() }, sleep: { try await clock.sleep($0) }))
    let current = server.generation
    await server.listenerStateChanged(.ready, port: 12345, generation: current)
    let connection = NWConnection(host: "127.0.0.1", port: 12345, using: .tcp)
    let peer = try #require(server.reservePeer(connection: connection, port: 12345, generation: current))
    peer.beginReadDeadline()
    while (await clock.durations).isEmpty { await Task.yield() }
    let request = rawRequest(port: 12345, body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
    #expect(await clock.durations == [5])
    peer.received(data: request, complete: false, failed: false)
    while !(await clock.cancelling) { await Task.yield() }
    var returned = false
    let shutdown = Task { @MainActor in
        await server.stop()
        #expect(await clock.cleaned)
        returned = true
    }
    while !peer.closed { await Task.yield() }
    // Give the queued shutdown continuation an opportunity to run while the
    // manually controlled read cleanup remains suspended.
    for _ in 0..<100 { await Task.yield() }
    #expect(!returned)
    await clock.finishCleanup()
    await shutdown.value
    #expect(await clock.cleaned)
}

actor QuietReadClock {
    func sleep() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        defer { continuation.finish() }
        for await _ in stream { }
        try Task.checkCancellation()
    }
}
