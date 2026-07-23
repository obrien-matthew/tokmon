// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "tokmon",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "tokmon", path: "Sources/tokmon"),
        .testTarget(name: "tokmonTests", dependencies: ["tokmon"], path: "Tests/tokmonTests")
    ]
)
