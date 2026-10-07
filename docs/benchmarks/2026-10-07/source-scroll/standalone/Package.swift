// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScrollProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/krzyzanowskim/STTextView",
            revision: "bbdcfd9d413ad3055dafd23a223be9bd39742f89"
        )
    ],
    targets: [
        .executableTarget(
            name: "ScrollProbe",
            dependencies: [.product(name: "STTextView", package: "STTextView")]
        ),
        .testTarget(name: "ScrollProbeTests", dependencies: ["ScrollProbe"]),
    ]
)
