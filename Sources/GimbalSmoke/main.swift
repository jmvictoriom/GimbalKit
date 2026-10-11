import Foundation
import GimbalKit
import GimbalKitBLE
import GimbalKitDJI

// Uso: GimbalSmoke [--mover]    (salida por stdout; sin --mover no manda ninguna orden de movimiento)
let move = CommandLine.arguments.contains("--mover")
let transport = CoreBluetoothOMTransport()
let device = OMDevice(transport: transport)

do {
    try await transport.connect(timeout: 15)
    print("CONECTADA")
    await device.start()
    try await Task.sleep(for: .seconds(4))
    print("POSE_INICIAL \(String(describing: await device.currentPose()))")
    print("BATERIA \(String(describing: await device.battery))")
    if move {
        for yaw in [10.0, -10.0] {                      // 10 °/s durante 2 s y de vuelta
            let end = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < end {
                try await device.send(.speed(yaw: yaw, pitch: 0, roll: 0))
                try await Task.sleep(for: .milliseconds(300))
            }
            try await device.send(.stop)
            try await Task.sleep(for: .seconds(2))
            print("POSE tras \(yaw) °/s: \(String(describing: await device.currentPose()))")
        }
    }
    try await device.send(.stop)
    await device.shutdown()
    transport.disconnect()
    print("FIN_OK")
} catch {
    try? await device.send(.stop)
    print("ERROR \(error)")
}
