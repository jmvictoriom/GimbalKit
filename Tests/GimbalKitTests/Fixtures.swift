import Foundation
import GimbalKit
import GimbalKitSim

let deskZone = Zone(name: "mesa", yaw: -30...30, pitch: -20...20)
let doorZone = Zone(name: "puerta", yaw: 60...90, pitch: -10...10)
let wideZone = Zone(name: "ancha", yaw: -180...180, pitch: -90...90)
let bathZone = Zone(name: "baño", yaw: 120...180, pitch: -90...90, forbidden: true)

func makePolicy(zones: [Zone] = [deskZone, doorZone, wideZone, bathZone]) -> SafetyPolicy {
    SafetyPolicy(maxSpeed: 60, maxLeaseSeconds: 30, deadmanSeconds: 0.5, zones: zones)
}

func makeController(
    capabilities: Capabilities = [.speedControl, .absoluteControl, .poseFeedback],
    zones: [Zone] = [deskZone, doorZone, wideZone, bathZone]
) -> (controller: GimbalController, sim: SimGimbal, clock: ManualClock) {
    let sim = SimGimbal(capabilities: capabilities)
    let clock = ManualClock()
    let controller = GimbalController(device: sim, policy: makePolicy(zones: zones), now: { clock.now() })
    return (controller, sim, clock)
}
