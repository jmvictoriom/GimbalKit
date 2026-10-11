import Foundation

public struct Lease: Sendable, Equatable {
    public let id: UUID
    public let source: ControlSource
    public let zone: String
    public let expiresAt: Date

    public init(id: UUID = UUID(), source: ControlSource, zone: String, expiresAt: Date) {
        self.id = id
        self.source = source
        self.zone = zone
        self.expiresAt = expiresAt
    }
}
