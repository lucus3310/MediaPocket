// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaPocketCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "MediaPocketCore", targets: ["MediaPocketCore"])],
    targets: [
        .target(name: "MediaPocketCore", path: "Sources/Core"),
        .testTarget(name: "MediaPocketCoreTests", dependencies: ["MediaPocketCore"], path: "Tests")
    ]
)
