import SwiftUI
import WidgetKit

@main
struct GimbalPhoneWidgets: WidgetBundle {
    var body: some Widget {
        GimbalStatusWidget()
        GimbalLiveActivityWidget()
        if #available(iOS 18.0, *) {
            GimbalStopControl()
        }
    }
}
