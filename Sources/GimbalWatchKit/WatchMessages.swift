import CoreFoundation
import Foundation

public enum WatchCommand: Codable, Sendable, Equatable {
    case stop
    case look(zone: String)
    case status
}

public struct WatchRequest: Codable, Sendable, Equatable {
    public let session: UUID
    public let seq: UInt64
    public let operationID: UUID?
    public let stopToken: UInt64?
    public let command: WatchCommand

    public init(session: UUID, seq: UInt64, operationID: UUID?, stopToken: UInt64?, command: WatchCommand) {
        self.session = session
        self.seq = seq
        self.operationID = operationID
        self.stopToken = stopToken
        self.command = command
    }
}

public enum WatchRejection: String, Codable, Sendable, Equatable {
    case malformed, unsupportedVersion, outOfOrder, staleAfterStop
    case quietPeriod, busy, zoneNotFound, disconnected, referenceRequired
    case stalePose, unsafePath, timeout, interrupted, policyRejected, failed
}

public enum WatchEvent: Codable, Sendable, Equatable {
    case arrived(operationID: UUID, stopCounter: UInt64)
    case stopped(operationID: UUID, stopCounter: UInt64)
    case rejected(operationID: UUID, reason: WatchRejection)
}

public struct WatchEventEnvelope: Codable, Sendable, Equatable {
    public let session: UUID?
    public let event: WatchEvent

    public init(session: UUID?, event: WatchEvent) {
        self.session = session
        self.event = event
    }
}

public struct WatchPose: Codable, Sendable, Equatable {
    public let yaw: Double
    public let pitch: Double
    public let roll: Double

    public init(yaw: Double, pitch: Double, roll: Double) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }
}

public struct WatchStatus: Codable, Sendable, Equatable {
    public let stopToken: UInt64
    public let connected: Bool
    public let batteryPercent: Int?
    public let pose: WatchPose?
    public let zoneNames: [String]
    public let terminalEvent: WatchEventEnvelope?

    public init(stopToken: UInt64, connected: Bool, batteryPercent: Int?, pose: WatchPose?, zoneNames: [String], terminalEvent: WatchEventEnvelope? = nil) {
        self.stopToken = stopToken
        self.connected = connected
        self.batteryPercent = batteryPercent
        self.pose = pose
        self.zoneNames = zoneNames
        self.terminalEvent = terminalEvent
    }
}

public struct WatchOperationState: Sendable, Equatable {
    public private(set) var currentOperationID: UUID?

    private var latestStopToken: UInt64 = 0

    public init() {}
    public mutating func observeStopToken(_ token: UInt64) {
        latestStopToken = max(latestStopToken, token)
    }
    public mutating func begin(_ id: UUID) { currentOperationID = id }

    public mutating func apply(_ event: WatchEvent) -> WatchEvent? {
        let id: UUID
        switch event {
        case let .arrived(operationID, _), let .stopped(operationID, _):
            id = operationID
        case let .rejected(operationID, _):
            id = operationID
        }
        guard currentOperationID == id else { return nil }
        if case let .arrived(_, token) = event, token < latestStopToken { return nil }
        currentOperationID = nil
        return event
    }
}

public enum WatchMessageError: Error, Sendable, Equatable {
    case malformed, unsupportedVersion, invalidSequence, invalidSession
    case invalidOperationID, invalidZone, invalidStatus
}

public enum WatchMessageCodec {
    public static func encodeRequest(_ request: WatchRequest) -> [String: Any] {
        var result: [String: Any] = [
            "version": NSNumber(value: 1),
            "session": request.session.uuidString,
            "seq": NSNumber(value: request.seq)
        ]
        switch request.command {
        case .stop:
            result["command"] = "stop"
            if let operationID = request.operationID { result["operationID"] = operationID.uuidString }
        case let .look(zone):
            result["command"] = "look"
            result["zone"] = zone
            if let operationID = request.operationID { result["operationID"] = operationID.uuidString }
            if let stopToken = request.stopToken { result["stopToken"] = NSNumber(value: stopToken) }
        case .status:
            result["command"] = "status"
        }
        return result
    }

    public static func decodeRequest(_ values: [String: Any]) throws -> WatchRequest {
        guard let version = unsigned(values["version"]), version == 1 else {
            throw WatchMessageError.unsupportedVersion
        }
        guard let sessionText = values["session"] as? String, let session = UUID(uuidString: sessionText) else {
            throw WatchMessageError.invalidSession
        }
        guard let seq = unsigned(values["seq"]) else { throw WatchMessageError.invalidSequence }
        guard let command = values["command"] as? String else { throw WatchMessageError.malformed }

        switch command {
        case "stop":
            guard Set(values.keys) == ["version", "session", "seq", "command", "operationID"],
                  let id = uuid(values["operationID"]) else { throw WatchMessageError.invalidOperationID }
            return WatchRequest(session: session, seq: seq, operationID: id, stopToken: nil, command: .stop)
        case "look":
            guard Set(values.keys) == ["version", "session", "seq", "command", "zone", "operationID", "stopToken"],
                  let id = uuid(values["operationID"]) else { throw WatchMessageError.invalidOperationID }
            guard let stopToken = unsigned(values["stopToken"]) else { throw WatchMessageError.invalidSequence }
            guard let zone = values["zone"] as? String,
                  !zone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WatchMessageError.invalidZone
            }
            return WatchRequest(session: session, seq: seq, operationID: id, stopToken: stopToken, command: .look(zone: zone))
        case "status":
            guard Set(values.keys) == ["version", "session", "seq", "command"] else {
                throw WatchMessageError.malformed
            }
            return WatchRequest(session: session, seq: seq, operationID: nil, stopToken: nil, command: .status)
        default:
            throw WatchMessageError.malformed
        }
    }

    public static func encodeEvent(_ envelope: WatchEventEnvelope) -> [String: Any] {
        var result: [String: Any] = ["version": NSNumber(value: 1)]
        if let session = envelope.session { result["session"] = session.uuidString }
        switch envelope.event {
        case let .arrived(id, stopCounter):
            result["event"] = "arrived"
            result["operationID"] = id.uuidString
            result["stopCounter"] = NSNumber(value: stopCounter)
        case let .stopped(id, stopCounter):
            result["event"] = "stopped"
            result["operationID"] = id.uuidString
            result["stopCounter"] = NSNumber(value: stopCounter)
        case let .rejected(id, reason):
            result["event"] = "rejected"
            result["operationID"] = id.uuidString
            result["reason"] = reason.rawValue
        }
        return result
    }

    public static func decodeEvent(_ values: [String: Any]) throws -> WatchEventEnvelope {
        guard let version = unsigned(values["version"]), version == 1 else {
            throw WatchMessageError.unsupportedVersion
        }
        let session = (values["session"] as? String).flatMap(UUID.init(uuidString:))
        guard values["session"] == nil || session != nil,
              let kind = values["event"] as? String,
              let id = uuid(values["operationID"]) else { throw WatchMessageError.malformed }
        let event: WatchEvent
        switch kind {
        case "arrived":
            guard let stopCounter = unsigned(values["stopCounter"]),
                  Set(values.keys) == ["version", "event", "operationID", "stopCounter"] ||
                  Set(values.keys) == ["version", "session", "event", "operationID", "stopCounter"] else {
                throw WatchMessageError.malformed
            }
            event = .arrived(operationID: id, stopCounter: stopCounter)
        case "stopped":
            guard let stopCounter = unsigned(values["stopCounter"]),
                  Set(values.keys) == ["version", "event", "operationID", "stopCounter"] ||
                  Set(values.keys) == ["version", "session", "event", "operationID", "stopCounter"] else {
                throw WatchMessageError.malformed
            }
            event = .stopped(operationID: id, stopCounter: stopCounter)
        case "rejected":
            guard let raw = values["reason"] as? String,
                  let reason = WatchRejection(rawValue: raw),
                  Set(values.keys) == ["version", "event", "operationID", "reason"] ||
                  Set(values.keys) == ["version", "session", "event", "operationID", "reason"] else {
                throw WatchMessageError.malformed
            }
            event = .rejected(operationID: id, reason: reason)
        default:
            throw WatchMessageError.malformed
        }
        return WatchEventEnvelope(session: session, event: event)
    }

    public static func encodeStatus(_ status: WatchStatus) -> [String: Any] {
        var result: [String: Any] = [
            "version": NSNumber(value: 1),
            "kind": "status",
            "stopToken": NSNumber(value: status.stopToken),
            "connected": NSNumber(value: status.connected),
            "zones": status.zoneNames
        ]
        if let battery = status.batteryPercent { result["batteryPercent"] = NSNumber(value: battery) }
        if let pose = status.pose {
            result["pose"] = [
                "yaw": NSNumber(value: pose.yaw),
                "pitch": NSNumber(value: pose.pitch),
                "roll": NSNumber(value: pose.roll)
            ]
        }
        if let terminalEvent = status.terminalEvent {
            result["terminalEvent"] = encodeEvent(terminalEvent)
        }
        return result
    }

    public static func decodeStatus(_ values: [String: Any]) throws -> WatchStatus {
        guard unsigned(values["version"]) == 1,
              values["kind"] as? String == "status",
              let stopToken = unsigned(values["stopToken"]),
              let connected = values["connected"] as? NSNumber,
              CFGetTypeID(connected) == CFBooleanGetTypeID(),
              let zones = values["zones"] as? [String],
              zones.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(values.keys).isSubset(of: Set(["version", "kind", "stopToken", "connected", "zones", "batteryPercent", "pose", "terminalEvent"])),
              Set(["version", "kind", "stopToken", "connected", "zones"]).isSubset(of: Set(values.keys)) else {
            throw WatchMessageError.invalidStatus
        }
        let battery: Int?
        if let raw = values["batteryPercent"] {
            guard let integer = unsigned(raw), integer <= 100 else { throw WatchMessageError.invalidStatus }
            battery = Int(integer)
        } else {
            battery = nil
        }
        let pose: WatchPose?
        if let raw = values["pose"] {
            guard let angles = raw as? [String: Any], Set(angles.keys) == ["yaw", "pitch", "roll"],
                  let yaw = finite(angles["yaw"]), let pitch = finite(angles["pitch"]),
                  let roll = finite(angles["roll"]) else { throw WatchMessageError.invalidStatus }
            pose = WatchPose(yaw: yaw, pitch: pitch, roll: roll)
        } else {
            pose = nil
        }
        let terminalEvent: WatchEventEnvelope?
        if let raw = values["terminalEvent"] {
            guard let object = raw as? [String: Any] else { throw WatchMessageError.invalidStatus }
            terminalEvent = try decodeEvent(object)
        } else {
            terminalEvent = nil
        }
        return WatchStatus(stopToken: stopToken, connected: connected.boolValue, batteryPercent: battery,
                           pose: pose, zoneNames: zones, terminalEvent: terminalEvent)
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let text = value as? String else { return nil }
        return UUID(uuidString: text)
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }

    private static func finite(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
