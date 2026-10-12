import GimbalHostSupport
import UIKit

@MainActor
struct PhoneHaptics: Haptics {
    func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    func stopImpact() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
}
