import ActivityKit
import GimbalWidgetSupport
import SwiftUI
import WidgetKit

struct GimbalLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GimbalActivityAttributes.self) { context in
            ActivityLockScreenView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color(red: 0.90, green: 0.91, blue: 0.94))
                .activitySystemActionForegroundColor(Color(red: 0.24, green: 0.27, blue: 0.39))
                .widgetURL(GimbalWidgetIdentity.appURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.isStale ? "Sin actualizar" : context.state.connectionText,
                          systemImage: "camera.aperture")
                        .font(.caption).foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label(context.state.batteryText, systemImage: "battery.100percent")
                        .font(.caption).foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        Text(context.isStale ? "Abre la app para actualizar" : context.state.operationText)
                            .font(.subheadline).lineLimit(1)
                        ActivityStopButton()
                    }
                }
            } compactLeading: {
                Image(systemName: "camera.aperture").foregroundStyle(WidgetColors.sky)
                    .accessibilityLabel("Osmo")
            } compactTrailing: {
                Text(context.isStale ? "—" : context.state.batteryText).font(.caption2)
            } minimal: {
                Image(systemName: context.isStale ? "questionmark.circle" : "camera.aperture")
                    .foregroundStyle(WidgetColors.sky)
            }
            .widgetURL(GimbalWidgetIdentity.appURL)
            .keylineTint(WidgetColors.violet)
        }
    }
}

private struct ActivityLockScreenView: View {
    let state: GimbalActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("GimbalKit", systemImage: "camera.aperture")
                    .font(.headline).foregroundStyle(WidgetColors.violet)
                Spacer()
                Label(state.batteryText, systemImage: state.charging ? "battery.100percent.bolt" : "battery.100percent")
                    .font(.subheadline)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stale ? "Sin actualizar" : state.connectionText).font(.caption)
                    Text(stale ? "Abre la app para actualizar" : state.operationText)
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                Spacer(minLength: 0)
                ActivityStopButton()
            }
        }
        .foregroundStyle(Color(red: 0.24, green: 0.27, blue: 0.39))
        .padding(16)
    }
}

private struct ActivityStopButton: View {
    var body: some View {
        Button(intent: StopGimbalLiveActivityIntent()) {
            Label("PARADA", systemImage: "stop.fill")
                .font(.headline).foregroundStyle(Color(red: 0.18, green: 0.05, blue: 0.07))
                .padding(.horizontal, 16).frame(minHeight: 44)
                .background {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(WidgetColors.red)
                        .shadow(color: .black.opacity(0.2), radius: 4, x: 3, y: 3)
                        .shadow(color: .white.opacity(0.25), radius: 4, x: -2, y: -2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Parada")
        .accessibilityHint("Detiene el estabilizador")
    }
}

enum WidgetColors {
    static let violet = Color(red: 0.486, green: 0.227, blue: 0.929)
    static let sky = Color(red: 0.055, green: 0.647, blue: 0.914)
    static let red = Color(red: 0.898, green: 0.282, blue: 0.302)
}
