// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SolidityBridge",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SolidityBridge", targets: ["SolidityBridge"]),
        .executable(name: "soliditybridge-bindings", targets: ["SolidityBridgeBindings"])
    ],
    targets: [
        .target(name: "SolidityBridge"),
        .executableTarget(name: "SolidityBridgeBindings", dependencies: ["SolidityBridge"]),
        .testTarget(name: "SolidityBridgeTests", dependencies: ["SolidityBridge"])
    ]
)
