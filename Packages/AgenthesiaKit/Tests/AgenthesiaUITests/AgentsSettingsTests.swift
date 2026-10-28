import ACP
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

    @Test func commandLinesQuoteWordsAShellWouldSplit() {
        #expect(
            AgentsSettings.commandLine(.init(executable: "/opt/homebrew/bin/opencode", arguments: ["acp"]))
                == "/opt/homebrew/bin/opencode acp"
        )
        #expect(
            AgentsSettings.commandLine(
                .init(executable: "/Users/me/My Agents/agent", arguments: ["it's", "", "$HOME"])
            )
                == #"'/Users/me/My Agents/agent' 'it'\''s' '' '$HOME'"#
        )
    }

    @Test func checkSummaryNamesTheAgentProtocolAndSignInMethods() throws {
        let method = try JSONDecoder().decode(ACP.AuthMethod.self, from: Data(#"{"id":"login","name":"Log In"}"#.utf8))
        #expect(
            AgentsSettings.summary(
                of: .init(protocolVersion: 1, info: .init(name: "opencode", title: "OpenCode", version: "2.2.0"))
            ) == "Speaks ACP v1 · OpenCode 2.2.0 · no sign-in methods"
        )
        #expect(
            AgentsSettings.summary(of: .init(protocolVersion: 1, authMethods: [method]))
                == "Speaks ACP v1 · 1 sign-in method"
        )
        #expect(
            AgentsSettings.summary(
                of: .init(protocolVersion: 1, info: .init(name: "x", version: "1"), authMethods: [method, method])
            )
                == "Speaks ACP v1 · x 1 · 2 sign-in methods"
        )
    }

    @Test func hostedAgentsTabShowsTheRegistryNodeStatusAndLocalAgents() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agh-agents-settings-\(UUID())")
        let suite = "agh-agents-settings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["opencode", "goose", "claude"] {
            try Data("#!/bin/sh\n".utf8).write(to: bin.appending(path: name))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: bin.appending(path: name).path(percentEncoded: false)
            )
        }
        let path = bin.path(percentEncoded: false)
        let data = try JSONSerialization.data(withJSONObject: [
            "version": "1.0.0",
            "agents": [
                metadata(distribution: ["npx": ["package": "@example/agent@1.0.0"]])
            ],
        ])
        let catalog = AgentCatalog(
            registry: AgentRegistry.Client(cacheDirectory: root) { _ in .init(status: 200, data: data) },
            installer: AgentInstaller(root: root.appending(path: "Agents"), download: { _, _ in }),
            defaults: defaults,
            environment: { _ in ["PATH": path] },
            probe: { _ in throw AgentProbe.Failure.timedOut(seconds: 20) },
            checkNode: { _ in throw NodeRuntime.Failure.missingNode }
        )
        await catalog.refresh()
        #expect(catalog.needsNode)
        catalog.add(try #require(catalog.addable.first))
        await catalog.check(try #require(catalog.localAgents.first).command)
        #expect(catalog.addable.map(\.entry.executable) == ["opencode"])
        #expect(catalog.suggestions.map(\.entry.executable) == ["claude"])
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
