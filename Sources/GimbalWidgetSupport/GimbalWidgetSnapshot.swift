import Foundation

public struct GimbalWidgetSnapshot: Sendable, Codable, Equatable {
    public let state: GimbalActivityAttributes.ContentState
    public let updatedAt: Date

    public init(state: GimbalActivityAttributes.ContentState, updatedAt: Date) {
        self.state = state
        self.updatedAt = updatedAt
    }

    /// A widget is a cached observation, never proof of a live BLE connection.
    public func isStale(at date: Date) -> Bool {
        let age = date.timeIntervalSince(updatedAt)
        return age < 0 || age >= 30
    }
}

public struct GimbalWidgetSnapshotStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func read() -> GimbalWidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GimbalWidgetSnapshot.self, from: data)
    }

    public func write(_ snapshot: GimbalWidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    #if os(iOS)
    public static var shared: Self? {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: GimbalWidgetIdentity.appGroup
        ) else { return nil }
        return Self(url: root.appendingPathComponent("gimbal-widget-status.json"))
    }
    #endif
}
