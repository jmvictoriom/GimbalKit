import Foundation
import GimbalKit

public struct BatteryStatus: Sendable, Codable, Equatable {
    public let percent: Int
    public let charging: Bool
    public init(percent: Int, charging: Bool) { self.percent = percent; self.charging = charging }
}
public struct LeaseStatus: Sendable, Codable, Equatable {
    public let zone: String
    public let expiresAt: Date
    public let remainingSeconds: Double
    public init(zone: String, expiresAt: Date, remainingSeconds: Double) {
        self.zone = zone; self.expiresAt = expiresAt; self.remainingSeconds = remainingSeconds
    }
}
public struct GimbalStatus: Sendable, Codable, Equatable {
    public let connected: Bool
    public let referenceReady: Bool
    public let battery: BatteryStatus?
    public let pose: Pose?
    public let lease: LeaseStatus?
    public init(connected: Bool, referenceReady: Bool, battery: BatteryStatus?, pose: Pose?, lease: LeaseStatus?) {
        self.connected = connected; self.referenceReady = referenceReady
        self.battery = battery; self.pose = pose; self.lease = lease
    }
}
public struct GimbalLookResult: Sendable, Codable, Equatable {
    public let status: GimbalStatus
    public let arrivalPose: Pose
    public init(status: GimbalStatus, arrivalPose: Pose) {
        self.status = status; self.arrivalPose = arrivalPose
    }
}
public protocol GimbalService: Sendable {
    func status() async throws -> GimbalStatus
    func zones() async throws -> [ZoneRecord]
    func look(zone: String, leaseSeconds: Double) async throws -> GimbalLookResult
    func stop() async throws
}
