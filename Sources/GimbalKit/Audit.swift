import Foundation

public struct AuditEntry: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case accepted
        case rejected(String)
    }

    public let date: Date
    public let source: ControlSource?
    public let event: String
    public let outcome: Outcome

    public init(date: Date, source: ControlSource?, event: String, outcome: Outcome) {
        self.date = date
        self.source = source
        self.event = event
        self.outcome = outcome
    }
}

public actor AuditLog {
    private let capacity: Int
    private var stored: [AuditEntry] = []

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    public func record(_ entry: AuditEntry) {
        stored.append(entry)
        if stored.count > capacity { stored.removeFirst(stored.count - capacity) }
    }

    public func entries() -> [AuditEntry] { stored }
}
