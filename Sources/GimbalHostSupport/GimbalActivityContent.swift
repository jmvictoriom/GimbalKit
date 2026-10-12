import GimbalKitMCP
import GimbalWidgetSupport

/// Only the public runtime status is observed; no control or navigation behavior changes.
public enum GimbalActivityContent {
    public static func state(for status: GimbalStatus, lastZone: String?) -> GimbalActivityAttributes.ContentState {
        let zone = status.connected ? status.lease?.zone : nil
        return .init(connected: status.connected,
                     batteryPercent: status.connected ? status.battery?.percent : nil,
                     charging: status.connected && (status.battery?.charging ?? false),
                     lookingAtZone: zone, lastZone: zone ?? lastZone)
    }
}
