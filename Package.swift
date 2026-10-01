// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MCPBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .executable(name: "mcp-bridge", targets: ["BridgeCLI"]),
        .executable(name: "MCPBridgeApp", targets: ["BridgeApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.1")
    ],
    targets: [
        .target(name: "BridgeCore", dependencies: [.product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")]),
        .executableTarget(name: "BridgeCLI", dependencies: ["BridgeCore"]),
        .executableTarget(name: "BridgeApp", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"])
    ]
)
