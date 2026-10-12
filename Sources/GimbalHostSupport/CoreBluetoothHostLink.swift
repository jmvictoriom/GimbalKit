import Foundation
import GimbalKitDJI
import GimbalKitBLE

#if os(iOS)
public final class CoreBluetoothHostLink: HostLink, Sendable {
    public let transport: CoreBluetoothOMTransport
    public let disconnects: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    public var notifications: AsyncStream<[UInt8]> { transport.notifications }

    public init() {
        let pair = AsyncStream.makeStream(of: Void.self)
        disconnects = pair.stream
        continuation = pair.continuation
        transport = CoreBluetoothOMTransport()
        transport.onDisconnect = { pair.continuation.yield(()) }
    }

    public func connect() async throws { try await transport.connect(timeout: 15) }
    public func disconnect() async { transport.disconnect(); continuation.finish() }
    public func write(_ bytes: [UInt8]) async throws { try await transport.write(bytes) }
}
#endif
