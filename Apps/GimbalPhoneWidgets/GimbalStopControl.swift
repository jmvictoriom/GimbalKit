import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct GimbalStopControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.gimbalkit.phone.stop") {
            ControlWidgetButton(action: OpenAndStopGimbalIntent()) {
                Label("Parada", systemImage: "stop.fill")
            }
        }
        .displayName("Parada")
        .description("Abre GimbalKit y detiene la Osmo.")
    }
}
