import Foundation
import Testing
import GimbalKit
import GimbalKitMCP
@testable import GimbalHostSupport

@MainActor final class FakeServer: MCPServerControl {
    var onUnexpectedTermination: (@MainActor @Sendable () -> Void)?
    private var continuation: CheckedContinuation<UInt16, any Error>?
    private(set) var starting = false
    private(set) var stops = 0
    let paused: Bool
    init(paused: Bool) { self.paused = paused }
    func start(port: UInt16) async throws -> UInt16 {
        starting = true
        if !paused { return port == 0 ? UInt16.max : port }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: { Task { @MainActor in await self.stop() } }
    }
    func stop() async { stops += 1; let c = continuation; continuation = nil; c?.resume(throwing: CancellationError()) }
}

@MainActor @Test func modelCancelsPendingServerStartAndCleansEndpoint() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try LocalFiles(directory: root)
    let link = FakeLink()
    let sleeper = StepSleeper()
    let clock = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let runtime = HostRuntime(makeLink: { link }, store: ZoneStore(url: root.appendingPathComponent("zones.json")), clock: clock)
    let server = FakeServer(paused: true)
    let model = HostModel(runtime: runtime, files: files, serverFactory: { _, _ in server }, clock: clock)
    await model.start()
    let enabling = Task { await model.setMCPEnabled(true) }
    #expect(await eventually { await server.starting })
    await model.setMCPEnabled(false)
    await enabling.value
    #expect(!model.mcpEnabled && model.activePort == nil && !model.serverBusy)
    #expect(server.stops > 0)
    #expect(throws: LocalFileError.missing) { try files.readEndpoint() }
    #expect(model.registrationCommand() == nil)
    await model.shutdown()
}

@MainActor @Test func modelPublishesPortAndExplicitRegistrationCommand() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try LocalFiles(directory: root)
    let link = FakeLink()
    let sleeper = StepSleeper()
    let clock = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let runtime = HostRuntime(makeLink: { link }, store: ZoneStore(url: root.appendingPathComponent("zones.json")), clock: clock)
    let model = HostModel(runtime: runtime, files: files, serverFactory: { _, _ in FakeServer(paused: false) }, clock: clock)
    model.port = 0
    await model.start(); await model.setMCPEnabled(true)
    #expect(model.mcpEnabled)
    #expect(try files.readEndpoint() == model.activePort)
    let command = try #require(model.registrationCommand())
    #expect(command.hasPrefix("claude mcp add --transport http gimbalkit http://127.0.0.1:"))
    #expect(command.contains(try files.token(create: false)))
    await model.shutdown()
    #expect(throws: LocalFileError.missing) { try files.readEndpoint() }
}

@Test func onlyOneHostCanOwnTheInstanceLock() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try LocalFiles(directory: root)
    do {
        let first = try HostInstanceLock(directory: root)
        #expect(throws: HostInstanceError.alreadyRunning) { try HostInstanceLock(directory: root) }
        withExtendedLifetime(first) {}
    }
    let next = try HostInstanceLock(directory: root)
    withExtendedLifetime(next) {}
}

@MainActor @Test func modelUnexpectedListenerTerminationRevokesLeaseAndClearsEndpoint() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try LocalFiles(directory: root)
    let link = FakeLink()
    let sleeper = StepSleeper()
    let clock = RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) })
    let runtime = HostRuntime(makeLink: { link }, store: ZoneStore(url: root.appendingPathComponent("zones.json")), clock: clock)
    let server = FakeServer(paused: false)
    let model = HostModel(runtime: runtime, files: files, serverFactory: { _, _ in server }, clock: clock)
    await model.start()
    #expect(await eventually { (try? await runtime.status().connected) == true })
    await link.attitude()
    #expect(await eventually { (try? await runtime.status().pose) != nil })
    let draft = try await runtime.prepareZone(name: "mesa")
    try await runtime.confirmZone(draft)
    await model.setMCPEnabled(true)
    let looking = Task { try await runtime.look(zone: "mesa", leaseSeconds: 30) }
    #expect(await eventually { (try? await runtime.status().lease) != nil })
    let termination = server.onUnexpectedTermination
    #expect(termination != nil)
    termination?()
    #expect(await eventually { @MainActor in !model.mcpEnabled && !model.serverBusy })
    #expect(model.activePort == nil)
    #expect(model.registrationCommand() == nil)
    #expect(throws: LocalFileError.missing) { try files.readEndpoint() }
    #expect(try await runtime.status().lease == nil)
    #expect(await runtime.auditEntries().contains { $0.source == .agent("mcp") && $0.event == "stop" })
    looking.cancel()
    _ = await looking.result
    await model.shutdown()
}
