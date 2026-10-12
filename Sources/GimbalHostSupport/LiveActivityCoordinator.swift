import Foundation
import GimbalKit
import GimbalKitMCP
import GimbalWidgetSupport

public protocol LiveActivityControlling: Sendable {
    func start(state: GimbalActivityAttributes.ContentState) async throws
    func update(state: GimbalActivityAttributes.ContentState) async
    /// Must end all activities of our type, including activities restored after relaunch.
    func end(state: GimbalActivityAttributes.ContentState) async
}

/// One serialized writer, latest-value coalescing and a trailing update at most once a second.
/// Disconnect bypasses the delay. An in-flight start/update always finishes before end,
/// so a late completion cannot resurrect an activity after disconnection.
public actor LiveActivityCoordinator {
    private let controller: any LiveActivityControlling
    private let clock: RuntimeClock
    private var latest: GimbalActivityAttributes.ContentState?
    private var lastZone: String?
    private var published: GimbalActivityAttributes.ContentState?
    private var lastWrite: Date?
    private var active = false
    private var cleanedUp = false
    private var mustEnd = false
    private var worker: Task<Void, Never>?
    private var delay: Task<Void, Error>?

    public init(controller: any LiveActivityControlling, clock: RuntimeClock = .live, initialLastZone: String? = nil) {
        self.controller = controller
        self.clock = clock
        self.lastZone = initialLastZone
    }

    public func receive(_ status: GimbalStatus) {
        let state = GimbalActivityContent.state(for: status, lastZone: lastZone)
        lastZone = state.lastZone
        latest = state
        if !state.connected {
            mustEnd = !cleanedUp || active || mustEnd
            delay?.cancel()
        }
        if worker == nil { worker = Task { await self.drain() } }
    }

    public func finish() async {
        receive(GimbalStatus(connected: false, referenceReady: false, battery: nil, pose: nil, lease: nil))
        await worker?.value
    }

    private func drain() async {
        while let state = latest {
            // Preserve even a brief disconnect followed by reconnect while the driver awaits.
            if mustEnd {
                mustEnd = false
                active = false
                cleanedUp = true
                published = nil
                lastWrite = nil
                await controller.end(state: .init(connected: false, batteryPercent: nil, lastZone: lastZone))
                continue
            }
            if !state.connected {
                latest = nil
                continue
            }
            // Refresh freshness for an idle connected rig, without telemetry-sized content.
            if active && state == published,
               let lastWrite, clock.now().timeIntervalSince(lastWrite) < 15 {
                latest = nil
                continue
            }
            if let lastWrite {
                let remaining = 1 - clock.now().timeIntervalSince(lastWrite)
                if remaining > 0 {
                    let clock = clock
                    let waiting = Task { try await clock.sleep(remaining) }
                    delay = waiting
                    _ = try? await waiting.value
                    delay = nil
                    continue // Reread the latest state after the suspension.
                }
            }
            latest = nil
            if active {
                await controller.update(state: state)
                published = state
            } else {
                cleanedUp = false
                do {
                    try await controller.start(state: state)
                    active = true
                    cleanedUp = false
                    published = state
                    // A disconnect can arrive while start() is suspended.
                    if mustEnd || latest?.connected == false { mustEnd = true }
                } catch {
                    // Retry on a later observation (e.g. when the app returns to foreground).
                    published = nil
                }
            }
            lastWrite = clock.now()
        }
        worker = nil
    }
}
