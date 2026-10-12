import AppIntents
#if !GIMBAL_WIDGET_EXTENSION
import GimbalHostSupport
#endif

/// Target membership: app AND extension. LiveActivityIntent makes iOS execute this
/// in the app process, using the exact same runtime that owns the BLE connection.
struct StopGimbalLiveActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Parada"
    static let description = IntentDescription("Detiene la Osmo desde la actividad en vivo.")
    static let openAppWhenRun = false
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if GIMBAL_WIDGET_EXTENSION
        // Never create a second runtime in an extension, even if routing is misconfigured.
        throw StopActivityIntentError.requiresAppProcess
        #else
        await PhoneHostEnvironment.shared.runtime.humanStop()
        #endif
        return .result()
    }
}

/// Control Center deliberately opens the app. Kept separate from the existing
/// StopGimbalIntent so its Shortcuts/Siri behavior is unchanged.
@available(iOS 18.0, *)
struct OpenAndStopGimbalIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir GimbalKit y parar"
    static let description = IntentDescription("Abre GimbalKit y detiene el estabilizador.")
    static let openAppWhenRun = true
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if GIMBAL_WIDGET_EXTENSION
        throw StopActivityIntentError.requiresAppProcess
        #else
        await PhoneHostEnvironment.shared.runtime.humanStop()
        #endif
        return .result()
    }
}

private enum StopActivityIntentError: Error { case requiresAppProcess }
