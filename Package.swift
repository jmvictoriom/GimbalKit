// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "GimbalKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GimbalKit", targets: ["GimbalKit"]),
        .library(name: "GimbalKitSim", targets: ["GimbalKitSim"]),
        .library(name: "GimbalKitDJI", targets: ["GimbalKitDJI"]),
        .library(name: "GimbalKitBLE", targets: ["GimbalKitBLE"]),
        .library(name: "GimbalKitMCP", targets: ["GimbalKitMCP"]),
    ],
    targets: [
        .target(name: "GimbalKit"),
        .target(name: "GimbalKitSim", dependencies: ["GimbalKit"]),
        .target(name: "GimbalKitDJI", dependencies: ["GimbalKit"]),
        .target(name: "GimbalKitBLE", dependencies: ["GimbalKitDJI"]),
        .target(name: "GimbalKitMCP", dependencies: ["GimbalKit"]),
        .executableTarget(name: "GimbalSmoke", dependencies: ["GimbalKitBLE", "GimbalKitDJI", "GimbalKit"]),
        .testTarget(name: "GimbalKitTests", dependencies: ["GimbalKit", "GimbalKitSim"]),
        .testTarget(name: "GimbalKitDJITests", dependencies: ["GimbalKitDJI", "GimbalKit"]),
        .testTarget(name: "GimbalKitMCPTests", dependencies: ["GimbalKitMCP", "GimbalKit"]),
    ]
)
