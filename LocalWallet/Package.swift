// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SolidityBridgeLocalWallet",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "SolidityBridgeLocalWallet", targets: ["SolidityBridgeLocalWallet"])],
    dependencies: [
        .package(name: "SolidityBridge", path: ".."),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", exact: "0.25.1")
    ],
    targets: [
        .target(
            name: "SolidityBridgeLocalWallet",
            dependencies: [
                .product(name: "SolidityBridge", package: "SolidityBridge"),
                .product(name: "libsecp256k1", package: "swift-secp256k1")
            ]
        ),
        .testTarget(name: "SolidityBridgeLocalWalletTests", dependencies: ["SolidityBridgeLocalWallet"])
    ]
)
