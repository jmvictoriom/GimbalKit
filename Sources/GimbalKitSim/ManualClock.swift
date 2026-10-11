import Foundation

public final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        current = start
    }

    public func now() -> Date { lock.withLock { current } }

    public func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
