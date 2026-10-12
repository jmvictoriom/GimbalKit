@preconcurrency import ActivityKit
import Foundation
import GimbalHostSupport
import GimbalWidgetSupport
import WidgetKit

@MainActor
final class PhoneLiveActivityController: LiveActivityControlling {
    private var activity: Activity<GimbalActivityAttributes>?

    func start(state: GimbalActivityAttributes.ContentState) async throws {
        let existing = Activity<GimbalActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
        if let restored = existing.first {
            activity = restored
            for duplicate in existing.dropFirst() { await duplicate.end(nil, dismissalPolicy: .immediate) }
            await restored.update(content(state))
        } else {
            activity = try Activity.request(attributes: GimbalActivityAttributes(), content: content(state), pushType: nil)
        }
    }

    func update(state: GimbalActivityAttributes.ContentState) async {
        await activity?.update(content(state))
    }

    func end(state: GimbalActivityAttributes.ContentState) async {
        // Clean up restored activities too, even if no request succeeded in this process.
        for current in Activity<GimbalActivityAttributes>.activities {
            await current.end(content(state), dismissalPolicy: .immediate)
        }
        activity = nil
    }

    private func content(_ state: GimbalActivityAttributes.ContentState) -> ActivityContent<GimbalActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
    }
}

@MainActor
final class PhoneWidgetPublisher {
    private let store = GimbalWidgetSnapshotStore.shared
    private var lastState: GimbalActivityAttributes.ContentState?
    private var lastSave: Date?
    private var lastReload: Date?
    private var reloadPending = false

    func publish(_ state: GimbalActivityAttributes.ContentState) {
        guard let store else { return }
        let now = Date()
        let changed = lastState != state
        if changed || lastSave.map({ now.timeIntervalSince($0) >= 15 }) ?? true {
            do {
                try store.write(.init(state: state, updatedAt: now))
                lastState = state
                lastSave = now
                reloadPending = true
            } catch { return }
        }
        // Widget timelines have a system budget; BLE telemetry never reloads them at 4 Hz.
        if reloadPending, lastReload.map({ now.timeIntervalSince($0) >= 15 }) ?? true {
            WidgetCenter.shared.reloadTimelines(ofKind: GimbalWidgetIdentity.kind)
            lastReload = now
            reloadPending = false
        }
    }
}
