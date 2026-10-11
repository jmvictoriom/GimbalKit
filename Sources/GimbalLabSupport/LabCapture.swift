import Foundation
import GimbalKit

public struct LabCaptureRecord: Codable, Sendable, Equatable {
    public let t: Double
    public let fase: String
    public let k: String?
    public let crc: Bool?
    public let hex: String?
    public let yaw: Double?
    public let pitch: Double?
    public let roll: Double?
    public init(t: Double, fase: String, k: String? = nil, crc: Bool? = nil, hex: String? = nil,
                yaw: Double? = nil, pitch: Double? = nil, roll: Double? = nil) {
        self.t = t; self.fase = fase; self.k = k; self.crc = crc; self.hex = hex
        self.yaw = yaw; self.pitch = pitch; self.roll = roll
    }
}

public enum LabCaptureReader {
    public static func read(_ data: Data) throws -> [LabCaptureRecord] {
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).map { try decoder.decode(LabCaptureRecord.self, from: Data($0)) }
    }
}

public actor LabSessionRecorder {
    private let clock: RuntimeClock
    private var startedAt: Date?
    private var phase = "pre"
    private var handle: FileHandle?
    public init(clock: RuntimeClock = .live) { self.clock = clock }
    public func start(at url: URL) throws {
        try stop()
        try Data().write(to: url, options: .atomic)
        handle = try FileHandle(forWritingTo: url)
        startedAt = clock.now()
    }
    public func setPhase(_ value: String) {
        let clean = String(value.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline && $0 >= " " }.prefix(64))
        phase = clean.isEmpty ? "sin-fase" : clean
    }
    public func recordRX(hex: String, crc: Bool) throws {
        try append(LabCaptureRecord(t: elapsed, fase: phase, k: "rx", crc: crc, hex: hex))
    }
    public func recordTX(yaw: Double, pitch: Double, roll: Double) throws {
        try append(LabCaptureRecord(t: elapsed, fase: phase, k: "tx", yaw: yaw, pitch: pitch, roll: roll))
    }
    public func stop() throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil; startedAt = nil
    }
    private var elapsed: Double { max(0, startedAt.map { clock.now().timeIntervalSince($0) } ?? 0) }
    private func append(_ record: LabCaptureRecord) throws {
        guard let handle else { return }
        var data = try JSONEncoder().encode(record)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}
