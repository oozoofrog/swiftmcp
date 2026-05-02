// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MultiTargetPackage",
    targets: [
        .target(name: "Core"),
        .target(name: "App", dependencies: ["Core"])
    ]
)
