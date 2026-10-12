import GimbalKit
import GimbalKitMCP
import GimbalWidgetSupport

/// Independent of views, so app intents and Watch requests are also reflected.
public actor PhoneActivityObserver {
    private let runtime: HostRuntime
    private let coordinator: LiveActivityCoordinator
    private let clock: RuntimeClock
    private let publish: @Sendable (GimbalActivityAttributes.ContentState) async -> Void
    private var lastZone: String?
    private var poller: Task<Void, Never>?

    public init(runtime: HostRuntime, coordinator: LiveActivityCoordinator, clock: RuntimeClock = .live,
                initialLastZone: String? = nil,
                publish: @escaping @Sendable (GimbalActivityAttributes.ContentState) async -> Void = { _ in }) {
        self.runtime = runtime
        self.coordinator = coordinator
        self.clock = clock
        self.lastZone = initialLastZone
        self.publish = publish
    }

    public func start() {
        guard poller == nil else { return }
        poller = Task { [weak self, clock] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await clock.sleep(0.25) } catch { return }
            }
        }
    }

    public func refresh() async {
        guard let status = try? await runtime.status() else { return }
        let state = GimbalActivityContent.state(for: status, lastZone: lastZone)
        lastZone = state.lastZone
        await coordinator.receive(status)
        await publish(state)
    }

    public func stop() async {
        let old = poller
        poller = nil
        old?.cancel()
        await old?.value
        await coordinator.finish()
        await publish(.init(connected: false, batteryPercent: nil, lastZone: lastZone))
    }
}
