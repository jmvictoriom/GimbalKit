import SwiftUI

@main
@MainActor
struct GimbalWatchApp: App {
    @State private var client: WatchConnectivityClient

    init() {
        let client = WatchConnectivityClient()
        _client = State(initialValue: client)
        client.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchHomeView(client: client)
        }
    }
}
