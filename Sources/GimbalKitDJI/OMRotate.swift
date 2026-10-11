/// Orden de giro de la serie OM (cmd_set 0x04). Unidades crudas del protocolo; la conversión a grados es del driver.
public struct OMRotate: Sendable, Equatable {
    public enum Mode: UInt8, Sendable {
        case relative = 0x04
        case absolute = 0x05
        case speed = 0x80
    }

    public var yaw: Int16
    public var pitch: Int16
    public var roll: Int16
    public var time: UInt8
    public var mode: Mode

    public init(yaw: Int16, pitch: Int16, roll: Int16, time: UInt8, mode: Mode) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.time = time
        self.mode = mode
    }

    public func frame(sequence: UInt16 = 1) -> DUMLFrame {
        func le(_ value: Int16) -> [UInt8] {
            let raw = UInt16(bitPattern: value)
            return [UInt8(raw & 0xFF), UInt8(raw >> 8)]
        }
        return DUMLFrame(
            sender: 0x02, receiver: 0x04, sequence: sequence, commandType: 0x00, commandSet: 0x04,
            command: mode == .speed ? 0x0C : 0x14,
            payload: le(yaw) + le(roll) + le(pitch) + [mode.rawValue, time]
        )
    }
}
