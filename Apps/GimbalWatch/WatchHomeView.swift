import Observation
import GimbalWatchKit
import SwiftUI
import WatchKit

@MainActor
struct WatchHomeView: View {
    @Bindable var client: WatchConnectivityClient

    var body: some View {
        VStack(spacing: 8) {
            Button(action: client.stop) {
                Label("PARAR", systemImage: "stop.fill")
                    .font(.headline.bold())
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)

            Text(client.reachable ? "iPhone conectado" : "iPhone no alcanzable")
                .font(.caption)
            if let error = client.connectionError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            if let status = client.status {
                Text(status.connected ? "Osmo conectada" : "Osmo desconectada")
                    .font(.caption)
                if let battery = status.batteryPercent { Text("Batería: \(battery)%").font(.caption) }
                if let pose = status.pose {
                    Text("Yaw \(pose.yaw.formatted(.number.precision(.fractionLength(0))))° · Pitch \(pose.pitch.formatted(.number.precision(.fractionLength(0))))°")
                        .font(.caption2)
                }
            }
            if case let .rejected(_, reason)? = client.lastEvent {
                Text("Rechazado: \(reason.rawValue)").font(.caption2).foregroundStyle(.red)
            }

            List(client.status?.zoneNames ?? [], id: \.self) { zone in
                Button {
                    client.look(zone: zone)
                } label: {
                    Label(zone, systemImage: "viewfinder")
                }
                .disabled(!client.reachable || client.status?.stopToken == nil)
            }
        }
        .onChange(of: client.lastEvent) { _, event in
            guard let event else { return }
            switch event {
            case .arrived(_, _):
                WKInterfaceDevice.current().play(.success)
            case .stopped(_, _):
                WKInterfaceDevice.current().play(.stop)
            case .rejected:
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }
}
