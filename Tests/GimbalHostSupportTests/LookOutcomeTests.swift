import Foundation
import Testing
import GimbalKit
import GimbalKitMCP
@testable import GimbalHostSupport

@MainActor private final class RecordingHaptics: Haptics {
    enum Event: Equatable { case success, warning, stop }
    var events: [Event] = []
    func success() { events.append(.success) }
    func warning() { events.append(.warning) }
    func stopImpact() { events.append(.stop) }
}

private enum LookScenario: CaseIterable, Sendable {
    case unchanged, nearCenter, moved, offCenter, failure
    var yawBefore: Double { self == .offCenter ? 3 : 0 }
    var yawAfter: Double {
        switch self {
        case .unchanged, .failure: 0
        case .nearCenter: 0.4
        case .moved: 5
        case .offCenter: 3
        }
    }
    var expected: LookOutcome {
        switch self {
        case .unchanged, .nearCenter: .alreadyInside("mesa")
        case .moved, .offCenter: .arrived("mesa")
        case .failure: .failed("mesa", LookFailureText.reason(for: NavigationError.timeout))
        }
    }
}

private actor FakeLook {
    let scenario: LookScenario
    private(set) var zones: [String] = []
    private(set) var tokens: [UInt64] = []
    init(_ scenario: LookScenario) { self.scenario = scenario }
    func look(zone: String, token: UInt64) throws -> GimbalLookResult {
        zones.append(zone); tokens.append(token)
        if scenario == .failure { throw NavigationError.timeout }
        let pose = Pose(yaw: scenario.yawAfter)
        return GimbalLookResult(status: GimbalStatus(connected: true, referenceReady: true,
            battery: nil, pose: pose, lease: nil), arrivalPose: pose)
    }
}

private actor SuspendedLook {
    private(set) var started = false
    private var continuation: CheckedContinuation<GimbalLookResult, Never>?
    func look() async -> GimbalLookResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func arrive() {
        continuation?.resume(returning: GimbalLookResult(status: GimbalStatus(
            connected: true, referenceReady: true, battery: nil, pose: Pose(), lease: nil), arrivalPose: Pose()))
        continuation = nil
    }
}

@Suite struct LookOutcomeTests {
    @Test func strictThresholdsAndInvalidSamples() {
        let bounds = ZoneRecord(Zone(name: "mesa", yaw: -10...10, pitch: -10...10))
        #expect(LookOutcome.success(zone: "mesa", bounds: bounds, before: Pose(), after: Pose(yaw: 0.499)) == .alreadyInside("mesa"))
        #expect(LookOutcome.success(zone: "mesa", bounds: bounds, before: Pose(), after: Pose(yaw: 0.5)) == .arrived("mesa"))
        #expect(LookOutcome.success(zone: "mesa", bounds: bounds, before: Pose(yaw: 2), after: Pose(yaw: 2)) == .arrived("mesa"))
        #expect(LookOutcome.success(zone: "mesa", bounds: bounds, before: Pose(yaw: 1.999), after: Pose(yaw: 1.999)) == .alreadyInside("mesa"))
        #expect(LookOutcome.success(zone: "mesa", bounds: bounds, before: Pose(), after: Pose(yaw: 0.4, pitch: 0.4)) == .arrived("mesa"))
        #expect(LookOutcome.success(zone: "mesa", bounds: bounds, before: Pose(), after: Pose(roll: 0.5)) == .arrived("mesa"))
        #expect(LookOutcome.success(zone: "mesa", bounds: bounds, before: nil, after: Pose()) == .arrived("mesa"))
        #expect(LookOutcome.success(zone: "mesa", bounds: bounds, before: Pose(yaw: .nan), after: Pose()) == .arrived("mesa"))
        #expect(LookOutcome.success(zone: "mesa", bounds: nil, before: Pose(), after: Pose()) == .arrived("mesa"))
        #expect(LookOutcome.idle.zone == nil)
    }

    @Test(arguments: LookScenario.allCases) @MainActor
    fileprivate func fakeLookCalculatesOutcomeAndFeedback(scenario: LookScenario) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ZoneStore(url: root.appendingPathComponent("zones.json"))
        try await store.save([Zone(name: "mesa", yaw: -10...10, pitch: -10...10)])
        let link = VariableAttitudeHostLink(), sleeper = StepSleeper(), fake = FakeLook(scenario)
        let environment = PhoneHostEnvironment(makeLink: { link }, store: store,
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        let haptics = RecordingHaptics()
        let model = PhoneHostModel(environment: environment, haptics: haptics,
            lookAction: { try await fake.look(zone: $0, token: $1) })
        try await environment.start()
        #expect(await eventually { (try? await environment.runtime.status().connected) == true })
        await link.attitude(yaw: 0)
        #expect(await eventually { (try? await environment.runtime.status().pose) != nil })
        if scenario.yawBefore != 0 {
            await link.attitude(yaw: scenario.yawBefore)
            #expect(await eventually { abs(((try? await environment.runtime.status().pose?.yaw) ?? 0) - scenario.yawBefore) < 0.001 })
        }
        await model.look(zone: "mesa")
        #expect(model.lookOutcome == scenario.expected)
        #expect(!model.isLooking)
        #expect(haptics.events == (scenario == .failure ? [.warning] : [.success]))
        #expect(await fake.zones == ["mesa"])
        #expect(await fake.tokens == [environment.motionStopCounter.read()])
        #expect(await link.writes.isEmpty)
        if scenario == .failure { #expect(model.errorMessage?.contains(LookFailureText.reason(for: NavigationError.timeout)) == true) }
        #expect(await eventually { await sleeper.requested.contains(6) })
        await sleeper.advance(6)
        #expect(await eventually { await model.lookOutcome == .idle })
        await model.shutdown()
    }

    @Test @MainActor func newerOutcomeCancelsPreviousExpiryAndStopCancelsLatest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = FakeLink(), sleeper = StepSleeper(), fake = FakeLook(.unchanged)
        let environment = PhoneHostEnvironment(makeLink: { link }, store: ZoneStore(url: root),
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        let haptics = RecordingHaptics()
        let model = PhoneHostModel(environment: environment, haptics: haptics,
            lookAction: { try await fake.look(zone: $0, token: $1) })
        try await environment.start()
        #expect(await eventually { (try? await environment.runtime.status().connected) == true })
        await model.look(zone: "primera")
        #expect(await eventually { await sleeper.requested.filter { $0 == 6 }.count == 1 })
        await model.look(zone: "segunda")
        #expect(await eventually { await sleeper.requested.filter { $0 == 6 }.count == 2 })
        #expect(model.lookOutcome == .arrived("segunda"))
        await model.humanStop()
        #expect(model.lookOutcome == .idle)
        #expect(haptics.events == [.success, .success, .stop])
        await sleeper.advance(6)
        #expect(model.lookOutcome == .idle)
        await model.shutdown()
    }

    @Test @MainActor func stopFeedbackWorksOfflineAndDeletionRefreshesModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ZoneStore(url: root.appendingPathComponent("zones.json"))
        try await store.save([Zone(name: "mesa", yaw: -10...10, pitch: -10...10)])
        let link = FakeLink(fails: true), sleeper = StepSleeper(), haptics = RecordingHaptics()
        let environment = PhoneHostEnvironment(makeLink: { link }, store: store,
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        let model = PhoneHostModel(environment: environment, haptics: haptics)
        await model.humanStop()
        #expect(haptics.events == [.stop])
        #expect(environment.motionStopCounter.read() == 1)
        try await environment.start()
        await model.refresh()
        #expect(model.zones.map(\.name) == ["mesa"])
        await model.deleteZone(name: "mesa")
        #expect(model.zones.isEmpty)
        #expect(try await store.load().isEmpty)
        await model.deleteZone(name: "otra")
        #expect(model.errorMessage?.contains("otra") == true)
        await model.shutdown()
    }
    @Test @MainActor func lateSuccessAfterStopDoesNotReportArrival() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = FakeLink(), sleeper = StepSleeper(), suspended = SuspendedLook(), haptics = RecordingHaptics()
        let environment = PhoneHostEnvironment(makeLink: { link }, store: ZoneStore(url: root),
            clock: RuntimeClock(now: { sleeper.now() }, sleep: { try await sleeper.sleep($0) }))
        let model = PhoneHostModel(environment: environment, haptics: haptics,
            lookAction: { _, _ in await suspended.look() })
        try await environment.start()
        #expect(await eventually { (try? await environment.runtime.status().connected) == true })
        let look = Task { await model.look(zone: "mesa") }
        #expect(await eventually { await suspended.started })
        await model.humanStop()
        await suspended.arrive()
        await look.value
        #expect(model.lookOutcome == .failed("mesa", LookFailureText.reason(for: NavigationError.interrupted)))
        #expect(haptics.events == [.stop, .warning])
        await model.shutdown()
    }

}
