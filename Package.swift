// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "GimbalKit", targets: ["GimbalKit"]),
    .library(name: "GimbalKitSim", targets: ["GimbalKitSim"]),
    .library(name: "GimbalKitDJI", targets: ["GimbalKitDJI"]),
    .library(name: "GimbalKitBLE", targets: ["GimbalKitBLE"]),
    .library(name: "GimbalLabSupport", targets: ["GimbalLabSupport"]),
]
var targets: [Target] = [
    .target(name: "GimbalKit"),
    .target(name: "GimbalKitSim", dependencies: ["GimbalKit"]),
    .target(name: "GimbalKitDJI", dependencies: ["GimbalKit"]),
    .target(name: "GimbalKitBLE", dependencies: ["GimbalKitDJI"]),
    .target(name: "GimbalLabSupport", dependencies: ["GimbalKit", "GimbalKitDJI"]),
    .testTarget(name: "GimbalKitTests", dependencies: ["GimbalKit", "GimbalKitSim"]),
    .testTarget(name: "GimbalKitDJITests", dependencies: ["GimbalKitDJI", "GimbalKit", "GimbalKitSim", "GimbalLabSupport"]),
]
#if os(macOS)
products += [
    .library(name: "GimbalKitMCP", targets: ["GimbalKitMCP"]),
    .library(name: "GimbalHostSupport", targets: ["GimbalHostSupport"]),
    .library(name: "GimbalKitIntents", targets: ["GimbalKitIntents"]),
    .executable(name: "gimbal", targets: ["GimbalCLI"]),
    .executable(name: "GimbalHostMac", targets: ["GimbalHostMac"]),
    .executable(name: "GimbalLabMac", targets: ["GimbalLabMac"]),
]
targets += [
    .target(name: "GimbalKitMCP", dependencies: ["GimbalKit"]),
    .target(name: "GimbalHostSupport", dependencies: ["GimbalKit", "GimbalKitDJI", "GimbalKitMCP", "GimbalKitBLE"]),
    .target(name: "GimbalKitIntents", dependencies: ["GimbalKit", "GimbalKitMCP", "GimbalHostSupport"]),
    .executableTarget(name: "GimbalCLI", dependencies: ["GimbalKitMCP"]),
    .executableTarget(name: "GimbalHostMac", dependencies: ["GimbalHostSupport", "GimbalKit", "GimbalKitBLE", "GimbalKitDJI", "GimbalKitMCP"]),
    .executableTarget(name: "GimbalLabMac", dependencies: ["GimbalLabSupport", "GimbalHostSupport", "GimbalKit", "GimbalKitBLE", "GimbalKitDJI"]),
    .executableTarget(name: "GimbalSmoke", dependencies: ["GimbalKitBLE", "GimbalKitDJI", "GimbalKit"]),
    .testTarget(name: "GimbalKitMCPTests", dependencies: ["GimbalKitMCP", "GimbalKit"]),
    .testTarget(name: "GimbalHostSupportTests", dependencies: ["GimbalHostSupport", "GimbalKit", "GimbalKitDJI", "GimbalKitMCP", "GimbalKitSim"]),
    .testTarget(name: "GimbalKitIntentsTests", dependencies: ["GimbalKitIntents", "GimbalHostSupport", "GimbalKit", "GimbalKitMCP"]),
]
#endif
let package = Package(name: "GimbalKit", platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)], products: products, targets: targets)
