// swift-tools-version: 6.2
import PackageDescription

var products: [Product] = [
    .library(name: "BridgeCore", targets: ["BridgeCore"]),
    .executable(name: "mcp-bridge", targets: ["BridgeCLI"])
]
var targets: [Target] = [
    .target(name: "BridgeCore", dependencies: [.product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")], path: "src/BridgeCore"),
    .executableTarget(name: "BridgeCLI", dependencies: ["BridgeCore"], path: "src/BridgeCLI"),
    .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"], path: "Tests/BridgeCoreTests")
]
#if os(macOS)
products.append(.executable(name: "MCPBridgeApp", targets: ["BridgeApp"]))
targets.append(.executableTarget(name: "BridgeApp", dependencies: ["BridgeCore"], path: "src/BridgeApp"))
#endif

let package = Package(
    name: "MCPBridge",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.1")
    ],
    targets: targets
)
