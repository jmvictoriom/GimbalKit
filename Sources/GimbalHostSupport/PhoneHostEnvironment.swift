import Foundation
import GimbalKit

public enum PhoneConnectionError: Error, Sendable, Equatable {
    case timedOut
}

public final class PhoneHostEnvironment: Sendable {
    #if os(iOS)
    public static let shared = PhoneHostEnvironment(
        makeLink: { CoreBluetoothHostLink() },
        store: ZoneStore(),
        clock: .live
    )
    #endif

    public let runtime: HostRuntime
    public let motionStopCounter: MotionStopCounter
    public let clock: RuntimeClock

    public init(
        makeLink: @escaping @Sendable () -> any HostLink,
        store: ZoneStore,
        clock: RuntimeClock = .live
    ) {
        let counter = MotionStopCounter()
        self.motionStopCounter = counter
        self.clock = clock
        self.runtime = HostRuntime(
            makeLink: makeLink,
            store: store,
            clock: clock,
            motionStopCounter: counter
        )
    }

    public func start() async throws {
        try await runtime.start()
    }

    public func waitUntilConnected(timeout: Double = 10) async throws {
        guard timeout.isFinite, timeout > 0 else { throw PhoneConnectionError.timedOut }
        try await runtime.start()
        let deadline = clock.now().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            let connected = try await runtime.status().connected
            try Task.checkCancellation()
            if connected { return }
            let remaining = deadline.timeIntervalSince(clock.now())
            guard remaining > 0 else { throw PhoneConnectionError.timedOut }
            try await clock.sleep(min(0.1, remaining))
        }
    }
}
