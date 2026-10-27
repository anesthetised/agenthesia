import Foundation
import Testing

@testable import AgentRuntime

@Suite struct AgentRegistryTests {
    @Test func readsMetadataAndPrefersTheCurrentPlatformBinary() throws {
        let catalog = try AgentRegistry.Catalog(
            data: registry([
                entry(
                    distribution: #"""
                        {"binary":{
                            "darwin-aarch64":{"archive":"https://example.com/arm.zip","cmd":"./bin/agent",
                                "args":["acp","a b"],"env":{"TOKEN_MODE":"local"},"sha256":"\#(digest)"},
                            "darwin-x86_64":{"archive":"https://example.com/intel.zip","cmd":"agent"}},
                         "npx":{"package":"@example/agent@1.2.3"}}
                        """#,
                    metadata: #"""
                        ,"repository":"https://example.com/source","website":"https://example.com",
                        "authors":["Example"],"license":"MIT","license_url":"https://example.com/license",
                        "icon":"https://example.com/icon.svg"
                        """#
                )
            ])
        )
        let agent = try #require(catalog.agents.first)
        #expect(catalog.version == "1.0.0")
        #expect(agent.id == "example")
        #expect(agent.name == "Example Agent")
        #expect(agent.version == "1.2.3")
        #expect(agent.description == "An example agent")
        #expect(agent.authors == ["Example"])
        #expect(agent.license == "MIT")
        #expect(agent.licenseURL?.absoluteString == "https://example.com/license")
        #expect(agent.repository?.absoluteString == "https://example.com/source")
        #expect(agent.website?.host == "example.com")
        #expect(agent.icon?.lastPathComponent == "icon.svg")
        guard case .binary(let binary) = agent.installation(for: .macOSArm64) else {
            Issue.record("Expected the ARM binary"); return
        }
        #expect(binary.archive.lastPathComponent == "arm.zip")
        #expect(binary.command == "./bin/agent")
        #expect(binary.arguments == ["acp", "a b"])
        #expect(binary.environment == ["TOKEN_MODE": "local"])
        #expect(binary.sha256 == digest)
        guard case .binary(let intel) = agent.installation(for: .macOSIntel) else {
            Issue.record("Expected the Intel binary"); return
        }
        #expect(intel.archive.lastPathComponent == "intel.zip")
        #expect(intel.arguments.isEmpty)
        #expect(intel.environment.isEmpty)
        #expect(intel.sha256 == nil)
    }

    @Test func fallsBackToNpmWithoutChoosingAnotherArchitecturesBinary() throws {
        let catalog = try AgentRegistry.Catalog(
            data: registry([
                entry(
                    distribution: #"""
                        {"binary":{"linux-aarch64":{"archive":"https://example.com/linux.zip","cmd":"agent"}},
                         "npx":{"package":"@example/agent@1.2.3","args":["--acp"],"env":{"MODE":"yes"}}}
                        """#
                )
            ])
        )
        let agent = try #require(catalog.agents.first)
        guard case .npm(let package) = agent.installation(for: .macOSArm64) else {
            Issue.record("Expected npm fallback"); return
        }
        #expect(package.package == "@example/agent@1.2.3")
        #expect(package.arguments == ["--acp"])
        #expect(package.environment == ["MODE": "yes"])
        #expect(agent.authors.isEmpty)
        #expect(agent.license == nil)
    }

    @Test func retainsUnsupportedAgentsAndUnknownFields() throws {
        let catalog = try AgentRegistry.Catalog(
            data: registry([
                entry(distribution: #"{"uvx":{"package":"example==1.2.3"}}"#),
                entry(distribution: #"{"future":{"anything":[1,2]}}"#, id: "future"),
                entry(
                    distribution: #"{"binary":{"linux-x86_64":{"archive":"https://example.com/a","cmd":"agent"}}}"#,
                    id: "linux"
                ),
            ])
        )
        #expect(catalog.agents.count == 3)
        #expect(catalog.agents[0].installation(for: .macOSArm64) == .unsupported(.uvx))
        #expect(catalog.agents[0].distribution.uvx?.package == "example==1.2.3")
        #expect(catalog.agents[1].distribution.unsupportedKinds == ["future"])
        #expect(catalog.agents[1].installation(for: .macOSArm64) == .unsupported(.noCompatibleDistribution))
        #expect(catalog.agents[2].installation(for: .macOSArm64) == .unsupported(.noCompatibleDistribution))
        #expect(AgentRegistry.Platform.current.rawValue.hasPrefix("darwin-"))
    }

    @Test func rejectsUnsupportedVersionsDuplicatesAndOversizedCatalogs() throws {
        #expect(throws: AgentRegistry.Failure.unsupportedVersion("2.0.0")) {
            try AgentRegistry.Catalog(data: registry([], version: "2.0.0"))
        }
        #expect(throws: AgentRegistry.Failure.invalidCatalog) {
            try AgentRegistry.Catalog(data: registry([entry(), entry()]))
        }
        #expect(throws: AgentRegistry.Failure.responseTooLarge) {
            try AgentRegistry.Catalog(data: Data(repeating: 32, count: AgentRegistry.maximumBytes + 1))
        }
        #expect(throws: AgentRegistry.Failure.invalidCatalog) {
            try AgentRegistry.Catalog(data: Data(#"{"version":"1.0.0","agents":false}"#.utf8))
        }
        #expect(throws: AgentRegistry.Failure.invalidCatalog) {
            try AgentRegistry.Catalog(data: registry((0...512).map { entry(id: "agent-\($0)") }))
        }
    }

    @Test(arguments: ["../outside", "", "Uppercase", "agent_with_underscores"])
    func rejectsInvalidAgentIdentifiers(_ id: String) {
        #expect(throws: AgentRegistry.Failure.invalidCatalog) {
            try AgentRegistry.Catalog(data: registry([entry(id: id)]))
        }
    }

    @Test(arguments: [
        #"{"binary":{"darwin-aarch64":{"archive":"http://example.com/a","cmd":"agent"}}}"#,
        #"{"binary":{"darwin-aarch64":{"archive":"https://user:pass@example.com/a","cmd":"agent"}}}"#,
        #"{"binary":{"darwin-aarch64":{"archive":"https://example.com/a","cmd":"../escape"}}}"#,
        #"{"binary":{"darwin-aarch64":{"archive":"https://example.com/a","cmd":"/bin/sh"}}}"#,
        #"{"binary":{"darwin-aarch64":{"archive":"https://example.com/a","cmd":"agent","sha256":"bad"}}}"#,
        #"{"npx":{"package":""}}"#,
        #"{"npx":{"package":"example","env":{"BAD=KEY":"value"}}}"#,
        #"{"npx":{"package":"example","args":["\u0000"]}}"#,
        #"{"npx":{"package":"--malicious"}}"#,
        #"{"npx":{"package":"https://example.com/package.tgz"}}"#,
        #"{"npx":{"package":"example@latest"}}"#,
    ]) func rejectsUnsafeKnownDistributions(_ distribution: String) {
        #expect(throws: AgentRegistry.Failure.invalidCatalog) {
            try AgentRegistry.Catalog(data: registry([entry(distribution: distribution)]))
        }
    }

    private let digest = String(repeating: "a", count: 64)
}

func registry(_ agents: [String], version: String = "1.0.0") -> Data {
    Data("{\"version\":\"\(version)\",\"agents\":[\(agents.joined(separator: ","))],\"extensions\":{}}".utf8)
}

func entry(
    distribution: String = #"{"npx":{"package":"example@1.2.3"}}"#,
    id: String = "example",
    metadata: String = ""
) -> String {
    """
    {"id":"\(id)","name":"Example Agent","version":"1.2.3","description":"An example agent",
     "distribution":\(distribution)\(metadata)}
    """
}
