import AppIntents
import GimbalHostSupport
import GimbalKitIntents
import GimbalWatchKit
import GimbalWidgetSupport
import SwiftUI

@main
@MainActor
struct GimbalPhoneApp: App, AppIntentsPackage {
    nonisolated static var includedPackages: [any AppIntentsPackage.Type] {
        [GimbalKitIntentsPackage.self]
    }

    @State private var model: PhoneHostModel
    @State private var watchBridge: PhoneWatchBridge
    @State private var activityObserver: PhoneActivityObserver

    init() {
        let environment = PhoneHostEnvironment.shared
        let model = PhoneHostModel(environment: environment, haptics: PhoneHaptics())
        let service = PhoneWatchService(runtime: environment.runtime)
        let bridge = PhoneWatchBridge(service: service)
        let widgetPublisher = PhoneWidgetPublisher()
        let lastZone = GimbalWidgetSnapshotStore.shared?.read()?.state.lastZone
        let coordinator = LiveActivityCoordinator(
            controller: PhoneLiveActivityController(), clock: environment.clock, initialLastZone: lastZone
        )
        let activityObserver = PhoneActivityObserver(
            runtime: environment.runtime, coordinator: coordinator, clock: environment.clock, initialLastZone: lastZone,
            publish: { state in await widgetPublisher.publish(state) }
        )
        _model = State(initialValue: model)
        _watchBridge = State(initialValue: bridge)
        _activityObserver = State(initialValue: activityObserver)
        bridge.activate()
        Task { @MainActor [model, service, bridge, activityObserver] in
            await activityObserver.start()
            await service.startObservingStopCounter()
            await model.start()
            await bridge.refreshStatus()
        }
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                PhoneHomeView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink {
                                PhoneSettingsView()
                            } label: {
                                Label("Ajustes", systemImage: "gearshape")
                            }
                        }
                    }
            }
        }
    }
}
