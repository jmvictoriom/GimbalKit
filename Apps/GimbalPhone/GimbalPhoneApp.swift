import AppIntents
import GimbalHostSupport
import GimbalKitIntents
import GimbalWatchKit
import SwiftUI

@main
@MainActor
struct GimbalPhoneApp: App, AppIntentsPackage {
    nonisolated static var includedPackages: [any AppIntentsPackage.Type] {
        [GimbalKitIntentsPackage.self]
    }

    @State private var model: PhoneHostModel
    @State private var watchBridge: PhoneWatchBridge

    init() {
        let environment = PhoneHostEnvironment.shared
        let model = PhoneHostModel(environment: environment, haptics: PhoneHaptics())
        let service = PhoneWatchService(runtime: environment.runtime)
        let bridge = PhoneWatchBridge(service: service)
        _model = State(initialValue: model)
        _watchBridge = State(initialValue: bridge)
        bridge.activate()
        Task { @MainActor [model, service, bridge] in
            await service.startObservingStopCounter()
            await model.start()
            await bridge.refreshStatus()
        }
    }

    var body: some Scene {
        WindowGroup {
            PhoneHomeView(model: model)
        }
    }
}
