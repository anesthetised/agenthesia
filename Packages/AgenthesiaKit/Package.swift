// swift-tools-version: 6.2

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "AgenthesiaKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgenthesiaUI", targets: ["AgenthesiaUI"]),
        .executable(name: "acp-cli", targets: ["acp-cli"]),
        .executable(name: "MockAgent", targets: ["MockAgent"]),
    ],
    targets: [
        .target(name: "JSONRPC", swiftSettings: swiftSettings),
        .target(name: "ACP", dependencies: ["JSONRPC"], swiftSettings: swiftSettings),
        .target(name: "AgentRuntime", dependencies: ["ACP"], swiftSettings: swiftSettings),
        .target(name: "Workspace", swiftSettings: swiftSettings),
        .target(name: "Persistence", swiftSettings: swiftSettings),
        .target(name: "Rendering", swiftSettings: swiftSettings),
        .target(
            name: "AgenthesiaCore",
            dependencies: ["ACP", "AgentRuntime", "Workspace", "Persistence"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AgenthesiaUI",
            dependencies: ["AgenthesiaCore", "Rendering"],
            swiftSettings: swiftSettings + [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(name: "acp-cli", dependencies: ["ACP", "AgentRuntime"], swiftSettings: swiftSettings),
        .executableTarget(name: "MockAgent", dependencies: ["ACP"], swiftSettings: swiftSettings),

        .testTarget(name: "JSONRPCTests", dependencies: ["JSONRPC"], swiftSettings: swiftSettings),
        .testTarget(name: "ACPTests", dependencies: ["ACP"], swiftSettings: swiftSettings),
        .testTarget(name: "AgentRuntimeTests", dependencies: ["AgentRuntime"], swiftSettings: swiftSettings),
        .testTarget(name: "WorkspaceTests", dependencies: ["Workspace"], swiftSettings: swiftSettings),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"], swiftSettings: swiftSettings),
        .testTarget(name: "RenderingTests", dependencies: ["Rendering"], swiftSettings: swiftSettings),
        .testTarget(name: "AgenthesiaCoreTests", dependencies: ["AgenthesiaCore"], swiftSettings: swiftSettings),
    ]
)
