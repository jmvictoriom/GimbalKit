import Foundation
import Testing
import GimbalKit
import GimbalKitDJI
import GimbalKitMCP
import GimbalKitSim
@testable import GimbalHostSupport

enum TestLinkError: Error { case failed }
actor FakeLink: HostLink {
    nonisolated let notifications: AsyncStream<[UInt8]>
    nonisolated let disconnects: AsyncStream<Void>
    private let bytes: AsyncStream<[UInt8]>.Continuation
    private let disconnected: AsyncStream<Void>.Continuation
    private let fails: Bool
    private(set) var writes: [[UInt8]] = []
    private(set) var closed = false
    init(fails: Bool = false) {
        self.fails = fails
        (notifications, bytes) = AsyncStream.makeStream(of: [UInt8].self)
        (disconnects, disconnected) = AsyncStream.makeStream(of: Void.self)
    }
    func connect() throws { if fails { throw TestLinkError.failed } }
    func disconnect() { closed = true; disconnected.finish(); bytes.finish() }
    func write(_ data: [UInt8]) { writes.append(data) }
    func drop() { disconnected.yield(()) }
    func attitude() {
        let hex = "553e044b04026e7c00040501f9fcff000084000300200132c503002c1800000c005403e36ab83eb4debbbea1fe193f98821cbf000000000100000000f6bc"
        let raw = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        bytes.yield(raw)
    }
}
final class LinkFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var links: [any HostLink]
    private var count = 0
    init(_ links: [any HostLink]) { self.links = links }
    func next() -> any HostLink { lock.withLock { count += 1; return links.removeFirst() } }
    var attempts: Int { lock.withLock { count } }
}
actor StepSleeper {
    let clock = ManualClock()
    private var continuations: [AsyncStream<Void>.Continuation] = []
    private(set) var requested: [Double] = []
    nonisolated func now() -> Date { clock.now() }
    func sleep(_ seconds: Double) async throws {
        requested.append(seconds)
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        continuations.append(continuation)
        for await _ in stream { break }
        try Task.checkCancellation()
    }
    func advance(_ seconds: Double) {
        clock.advance(seconds)
        let pending = continuations; continuations.removeAll()
        for continuation in pending { continuation.yield(()); continuation.finish() }
    }
}
func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<10000 { if await condition() { return true }; await Task.yield() }
    return false
}

@Test func hostBackoffReferenceConfirmationPersistenceAndDisconnect() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let failed = FakeLink(fails: true), good = FakeLink(), next = FakeLink()
    let factory = LinkFactory([failed, good, next])
    let sleeper = StepSleeper()
    let timing = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let store = ZoneStore(url: root.appendingPathComponent("zones.json"))
    let runtime = HostRuntime(makeLink: { factory.next() }, store: store, clock: timing)
    try await runtime.start()
    #expect(await eventually { await sleeper.requested.contains(0.5) })
    #expect(factory.attempts == 1)
    await sleeper.advance(0.5)
    #expect(await eventually { (try? await runtime.status().connected) == true })
    await good.attitude()
    #expect(await eventually { (try? await runtime.status().pose) != nil })
    let draft = try await runtime.prepareZone(name: "mesa")
    #expect(try await store.load().isEmpty)
    try await runtime.confirmZone(draft)
    #expect(try await store.load().first?.name == "mesa")
    #expect(try await runtime.status().referenceReady)
    await good.drop()
    #expect(await eventually { (try? await runtime.status().connected) == false })
    #expect(await eventually { await sleeper.requested.filter { $0 == 0.5 }.count == 2 })
    await sleeper.advance(0.5)
    #expect(await eventually {
        let connected = (try? await runtime.status().connected) == true
        return factory.attempts == 3 && connected
    })
    await next.attitude()
    #expect(await eventually { (try? await runtime.status().pose) != nil })
    #expect(try await runtime.status().referenceReady == false)
    await #expect(throws: NavigationError.referenceRequired) { try await runtime.look(zone: "mesa", leaseSeconds: 30) }
    let reference = try await runtime.prepareReference()
    try await runtime.confirmReference(reference)
    #expect(try await runtime.status().referenceReady)
    await runtime.humanStop()
    #expect(await runtime.auditEntries().contains { $0.source == .app && $0.event == "stop" })
    await runtime.shutdown()
    #expect(await next.closed)
    #expect(factory.attempts == 3)
}

@Test func backoffIsBounded() {
    #expect((0..<8).map(HostRuntime.backoff) == [0.5, 1, 2, 4, 8, 8, 8, 8])
}
