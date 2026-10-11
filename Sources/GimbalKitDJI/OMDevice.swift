import GimbalKit

public protocol OMTransport: Sendable {
    func write(_ bytes: [UInt8]) async throws
    var notifications: AsyncStream<[UInt8]> { get }
}

public enum OMDeviceError: Error, Equatable {
    case unsupported(String)
}

/// Osmo Mobile SE como `GimbalDevice`. Solo declara lo verificado en hardware.
///
/// Las órdenes de velocidad deben espaciarse ≥ 0,25 s (con 0,1 s la Osmo no obedeció) y la pose llega a ~1,5 Hz:
/// quien llame (el host) es responsable de la cadencia y de tratar la pose como retardada.
public actor OMDevice: GimbalDevice {
    public nonisolated let capabilities: Capabilities = [.speedControl, .poseFeedback, .battery]
    public private(set) var battery: (percent: Int, charging: Bool)?

    private let transport: any OMTransport
    private var parser = DUMLParser()
    private var estimator = OMPoseEstimator()
    private var listener: Task<Void, Never>?

    public init(transport: any OMTransport) {
        self.transport = transport
    }

    public func start() {
        guard listener == nil else { return }
        let stream = transport.notifications
        listener = Task { [weak self] in
            for await chunk in stream {
                await self?.ingest(chunk)
            }
        }
    }

    public func shutdown() {
        listener?.cancel()
        listener = nil
    }

    public func zeroPose() {
        estimator.zero()
    }

    public func send(_ command: MoveCommand) async throws {
        switch command {
        case let .speed(yaw, pitch, _):
            try await write(yaw: OMUnits.raw(forDegreesPerSecond: yaw), pitch: OMUnits.raw(forDegreesPerSecond: pitch))
        case .stop:
            try await write(yaw: 0, pitch: 0)
        case .absolute:
            throw OMDeviceError.unsupported("absolute")
        }
    }

    public func currentPose() -> Pose? {
        estimator.pose
    }

    private func write(yaw: Int16, pitch: Int16) async throws {
        let rotate = OMRotate(yaw: yaw, pitch: pitch, roll: 0, time: 10, mode: .speed)
        try await transport.write(rotate.frame().encoded())
    }

    private func ingest(_ chunk: [UInt8]) {
        for frame in parser.feed(chunk) {
            switch OMTelemetry.decode(frame) {
            case let .attitude(q)?: estimator.update(q)
            case let .battery(percent, charging)?: battery = (percent, charging)
            case nil: break
            }
        }
    }
}
