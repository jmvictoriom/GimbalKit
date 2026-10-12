import Foundation
#if os(iOS)
import ActivityKit
#endif

/// Values shared with the extension; this module never owns Bluetooth or a runtime.
public struct GimbalActivityAttributes: Sendable, Codable {
    public struct ContentState: Sendable, Codable, Hashable {
        public let connected: Bool
        public let batteryPercent: Int?
        public let charging: Bool
        public let lookingAtZone: String?
        public let lastZone: String?

        public init(connected: Bool, batteryPercent: Int?, charging: Bool = false,
                    lookingAtZone: String? = nil, lastZone: String? = nil) {
            self.connected = connected
            self.batteryPercent = batteryPercent.map { min(100, max(0, $0)) }
            self.charging = charging
            self.lookingAtZone = connected ? lookingAtZone : nil
            self.lastZone = lastZone
        }

        public var connectionText: String { connected ? "Conectada" : "Desconectada" }
        public var operationText: String {
            guard connected else { return "Desconectada" }
            return lookingAtZone.map { "Mirando a \($0)" } ?? "Quieta"
        }
        public var batteryText: String { batteryPercent.map { "\($0)%" } ?? "Sin datos" }
    }

    public init() {}
}

#if os(iOS)
extension GimbalActivityAttributes: ActivityAttributes {}
#endif

public enum GimbalWidgetIdentity {
    public static let kind = "dev.gimbalkit.phone.status"
    public static let appGroup = "group.dev.gimbalkit.phone"
    public static let appURL = URL(string: "gimbalkit://status")!
}
