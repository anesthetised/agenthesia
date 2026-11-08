// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "Orbit"),
        .testTarget(name: "OrbitTests", dependencies: ["Orbit"]),
    ]
)
