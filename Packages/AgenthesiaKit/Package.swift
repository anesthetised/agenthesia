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
        .executable(name: "rendering-bench", targets: ["rendering-bench"]),
        .executable(name: "persistence-bench", targets: ["persistence-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.9.0"),
        .package(url: "https://github.com/krzyzanowskim/STTextView", from: "2.4.1"),
        // SwiftTreeSitter moved to tree-sitter/swift-tree-sitter; grammars use both URLs, so the new one is mirrored
        // to the old one (.swiftpm/configuration/mirrors.json).
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.4-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.3"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
        // JavaScript, Python and YAML come from forks: upstream manifests look for src/scanner.c with a relative
        // fileExists check that fails under Xcode 27, dropping the scanner. Each fork is the release tag plus a
        // one-line manifest fix; switch back once upstream regenerates its manifests with tree-sitter 0.27.
        .package(
            url: "https://github.com/anesthetised/tree-sitter-javascript",
            revision: "a8b8b717dd0b3a88749bf884a20fff8fddf2960e"  // v0.25.0
        ),
        .package(
            url: "https://github.com/anesthetised/tree-sitter-python",
            revision: "cf0f4cb2fbe190fc8a2eca06d3e35d055b216786"  // v0.25.0
        ),
        .package(
            url: "https://github.com/anesthetised/tree-sitter-yaml",
            revision: "87306950722bff366a1281009da3bab77c9dbed8"  // v0.7.2
        ),
    ],
    targets: [
        .target(name: "JSONRPC", swiftSettings: swiftSettings),
        .target(name: "ACP", dependencies: ["JSONRPC"], swiftSettings: swiftSettings),
        .target(name: "AgentRuntime", dependencies: ["ACP"], swiftSettings: swiftSettings),
        .target(name: "Workspace", swiftSettings: swiftSettings),
        .target(
            name: "Persistence",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Rendering",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "STTextView", package: "STTextView"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
            ],
            swiftSettings: swiftSettings
        ),
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
        .executableTarget(
            name: "acp-cli",
            dependencies: [
                "ACP", "AgentRuntime", "JSONRPC", "Workspace",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(name: "rendering-bench", dependencies: ["Rendering"], swiftSettings: swiftSettings),
        .executableTarget(name: "persistence-bench", dependencies: ["Persistence"], swiftSettings: swiftSettings),
        .target(name: "ACPTesting", dependencies: ["ACP", "JSONRPC"], swiftSettings: swiftSettings),
        .executableTarget(name: "MockAgent", dependencies: ["ACPTesting", "JSONRPC"], swiftSettings: swiftSettings),

        .testTarget(
            name: "acp-cliTests",
            dependencies: ["acp-cli", "ACP", "ACPTesting", "JSONRPC", "MockAgent"],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "JSONRPCTests", dependencies: ["JSONRPC"], swiftSettings: swiftSettings),
        .testTarget(
            name: "ACPTests",
            dependencies: ["ACP", "ACPTesting"],
            exclude: ["Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "ACPTestingTests", dependencies: ["ACPTesting"], swiftSettings: swiftSettings),
        .testTarget(
            name: "AgentRuntimeTests",
            dependencies: ["AgentRuntime", "ACP", "ACPTesting", "JSONRPC", "MockAgent"],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "WorkspaceTests", dependencies: ["Workspace"], swiftSettings: swiftSettings),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "RenderingTests",
            dependencies: ["Rendering", .product(name: "STTextView", package: "STTextView")],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "AgenthesiaCoreTests", dependencies: ["AgenthesiaCore"], swiftSettings: swiftSettings),
        .testTarget(name: "AgenthesiaUITests", dependencies: ["AgenthesiaUI"], swiftSettings: swiftSettings),
    ]
)
