import GimbalWidgetSupport
import SwiftUI
import WidgetKit

private struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: GimbalWidgetSnapshot?
    var fresh: Bool { snapshot.map { !$0.isStale(at: date) } ?? false }
    var connection: String { fresh ? snapshot!.state.connectionText : "Sin actualizar" }
    var battery: String { snapshot?.state.batteryText ?? "Sin datos" }
    var zone: String { snapshot?.state.lastZone ?? "Sin zona" }
}

private struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snapshot: .init(state: .init(connected: true, batteryPercent: 80, lastZone: "Mesa"), updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let current = entry()
        var entries = [current]
        if current.fresh, let snapshot = current.snapshot {
            entries.append(StatusEntry(date: snapshot.updatedAt.addingTimeInterval(30), snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .after(current.date.addingTimeInterval(15 * 60))))
    }

    private func entry() -> StatusEntry {
        StatusEntry(date: .now, snapshot: GimbalWidgetSnapshotStore.shared?.read())
    }
}

struct GimbalStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GimbalWidgetIdentity.kind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .widgetURL(GimbalWidgetIdentity.appURL)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Estado de la Osmo")
        .description("Último estado observado: conexión, batería y zona. Toca para abrir GimbalKit.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

private struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("\(entry.connection) · \(entry.battery) · \(entry.zone)")
        case .accessoryCircular:
            VStack(spacing: 2) {
                Image(systemName: entry.fresh ? "camera.aperture" : "questionmark.circle")
                Text(entry.battery).font(.caption2)
            }
            .accessibilityLabel("\(entry.connection), batería \(entry.battery), última zona \(entry.zone)")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.connection).font(.headline)
                Text("\(entry.battery) · \(entry.zone)").font(.caption)
                if !entry.fresh { Text("Toca para actualizar").font(.caption2) }
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                Label("GimbalKit", systemImage: "camera.aperture")
                    .font(.headline).foregroundStyle(WidgetColors.violet)
                Text(entry.connection).font(.subheadline.weight(.semibold))
                Label(entry.battery, systemImage: "battery.100percent").font(.subheadline)
                Text("Última zona: \(entry.zone)").font(.caption).lineLimit(2)
                Text(entry.snapshot == nil ? "Abre la app" : "Última lectura")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
