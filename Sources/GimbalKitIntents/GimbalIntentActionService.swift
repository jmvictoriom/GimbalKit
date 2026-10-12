import Foundation
import GimbalKit
import GimbalKitMCP
import GimbalHostSupport

public protocol GimbalIntentRuntime: Sendable {
    var motionStopCounter: MotionStopCounter { get }
    func look(zone: String, leaseSeconds: Double, stopToken: UInt64?) async throws -> GimbalLookResult
    func humanStop() async
    func status() async throws -> GimbalStatus
    func prepareZone(name: String, forbidden: Bool) async throws -> ZoneDraft
    func confirmZone(_ draft: ZoneDraft) async throws
}

extension HostRuntime: GimbalIntentRuntime {}

public enum GimbalIntentActionService {
    public static func look(
        zone: String,
        runtime: any GimbalIntentRuntime,
        waitUntilConnected: @Sendable () async throws -> Void
    ) async throws -> GimbalLookResult {
        let token = runtime.motionStopCounter.read()
        try await waitUntilConnected()
        try Task.checkCancellation()
        return try await runtime.look(zone: zone, leaseSeconds: 30, stopToken: token)
    }

    public static func stop(runtime: any GimbalIntentRuntime) async {
        await runtime.humanStop()
    }

    public static func status(runtime: any GimbalIntentRuntime) async throws -> GimbalStatus {
        try await runtime.status()
    }

    public static func saveZone(
        name: String,
        forbidden: Bool = false,
        runtime: any GimbalIntentRuntime,
        confirm: @Sendable (ZoneDraft) async throws -> Void
    ) async throws {
        let draft = try await runtime.prepareZone(name: name, forbidden: forbidden)
        try await confirm(draft)
        try await runtime.confirmZone(draft)
    }

    public static func statusSummary(_ status: GimbalStatus) -> String {
        let connection = status.connected ? "Conectada" : "Desconectada"
        let battery = status.battery.map { "\($0.percent)%" } ?? "no disponible"
        let pose = status.pose.map { "yaw \($0.yaw.rounded())°, pitch \($0.pitch.rounded())°" } ?? "pose no disponible"
        return "Conexión: \(connection). Batería: \(battery). \(pose)."
    }
}
