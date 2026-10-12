import Foundation

/// Contador compartido entre actores. El lock protege tanto lectura como incremento.
public final class MotionStopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    #if DEBUG
    private let onRead: (@Sendable () -> Void)?
    #endif

    public init() {
        #if DEBUG
        onRead = nil
        #endif
    }

    #if DEBUG
    init(onRead: @escaping @Sendable () -> Void) {
        self.onRead = onRead
    }
    #endif

    public func read() -> UInt64 {
        #if DEBUG
        onRead?()
        #endif
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    public func increment() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        precondition(value < UInt64.max, "MotionStopCounter agotado")
        value += 1
        return value
    }
}
