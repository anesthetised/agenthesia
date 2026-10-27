import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentRuntime
@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor
@Suite struct AgentsSettingsTests {
    @Test func searchMatchesNameIDAndDescriptionInRegistryOrder() throws {
        let agents = try [
            agent(id: "alpha", name: "Alpha", description: "Writes code"),
            agent(id: "beta", name: "Beta", description: "Reviews diffs"),
        ]
        #expect(AgentsSettings.filter(agents, query: " ").map(\.id) == ["alpha", "beta"])
        #expect(AgentsSettings.filter(agents, query: "BET").map(\.id) == ["beta"])
        #expect(AgentsSettings.filter(agents, query: "diffs").map(\.id) == ["beta"])
        #expect(AgentsSettings.filter(agents, query: "missing").isEmpty)
    }

    @Test func installationNamesSourceLicenseAndWhatRuns() throws {
        let binary = try agent(
            license: "Apache-2.0",
            distribution: ["binary": [AgentRegistry.Platform.current.rawValue: binaryEntry]]
        )
        let message = AgentsSettings.installMessage(for: binary)
        #expect(message.contains("from https://github.com/example/agent"))
        #expect(message.contains("the Apache-2.0 license"))
        #expect(message.contains("downloads https://example.com/agent.tar. The registry declares no checksum."))
        #expect(AgentsSettings.distribution(of: binary) == "Binary for this Mac")

        let npm = try agent(distribution: ["npx": ["package": "@example/agent@1.0.0"]])
        #expect(AgentsSettings.installMessage(for: npm).contains("a license the registry does not state"))
        #expect(AgentsSettings.installMessage(for: npm).contains("npm installs @example/agent@1.0.0"))
        #expect(AgentsSettings.distribution(of: npm) == "npm package @example/agent@1.0.0")

        let uvx = try agent(distribution: ["uvx": ["package": "example-agent"]])
        #expect(AgentsSettings.distribution(of: uvx).contains("uv (uvx)"))
        let foreign = try agent(distribution: ["binary": ["linux-x86_64": binaryEntry]])
        #expect(AgentsSettings.distribution(of: foreign) == "No distribution for this Mac")
    }

    @Test func hostedAgentsTabShowsTheRegistryAndNodeStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agh-agents-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try JSONSerialization.data(withJSONObject: [
            "version": "1.0.0",
            "agents": [
                metadata(distribution: ["npx": ["package": "@example/agent@1.0.0"]])
            ],
        ])
        let catalog = AgentCatalog(
            registry: AgentRegistry.Client(cacheDirectory: root) { _ in .init(status: 200, data: data) },
            installer: AgentInstaller(root: root.appending(path: "Agents"), download: { _, _ in }),
            checkNode: { _ in throw NodeRuntime.Failure.missingNode }
        )
        await catalog.refresh()
        #expect(catalog.needsNode)
        let host = NSHostingView(rootView: AgentsSettings(catalog: catalog).frame(width: 600, height: 560))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 600)
        #expect(catalog.node == .unavailable(NodeRuntime.Failure.missingNode.localizedDescription))
    }

    private let binaryEntry: [String: Any] = ["archive": "https://example.com/agent.tar", "cmd": "bin/agent"]

    private func metadata(
        id: String = "example",
        name: String = "Example",
        description: String = "Test agent",
        license: String? = nil,
        distribution: [String: Any]
    ) -> [String: Any] {
        var metadata: [String: Any] = [
            "id": id, "name": name, "version": "1.0.0", "description": description,
            "repository": "https://github.com/example/agent", "distribution": distribution,
        ]
        metadata["license"] = license
        return metadata
    }

    private func agent(
        id: String = "example",
        name: String = "Example",
        description: String = "Test agent",
        license: String? = nil,
        distribution: [String: Any]? = nil
    ) throws -> AgentRegistry.Agent {
        try JSONDecoder().decode(
            AgentRegistry.Agent.self,
            from: JSONSerialization.data(
                withJSONObject: metadata(
                    id: id,
                    name: name,
                    description: description,
                    license: license,
                    distribution: distribution ?? ["npx": ["package": "\(id)@1.0.0"]]
                )
            )
        )
    }
}
