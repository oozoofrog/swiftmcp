// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swiftmcp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SwiftcMCPCore", targets: ["SwiftcMCPCore"]),
        .executable(name: "mcpswx", targets: ["mcpswx"]),
    ],
    targets: [
        .target(name: "SwiftcMCPCore"),
        .executableTarget(
            name: "mcpswx",
            dependencies: ["SwiftcMCPCore"]
        ),
        .testTarget(
            name: "SwiftcMCPCoreTests",
            dependencies: ["SwiftcMCPCore"]
        ),
    ]
)
