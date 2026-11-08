import ACP
import Foundation
import Persistence
import Testing

@testable import AgentRuntime
@testable import AgenthesiaCore

/// The draft's mode and model hints are applied after `session/new` and before the history record exists, and a
/// rejection leaves neither a record nor a worktree (ADR-0040, #211).
@MainActor @Suite(.timeLimit(.minutes(1))) struct ConfigHintTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agh-config-hints-\(UUID())")
        let suite = "agh-config-hints-\(UUID())"
        let library: SessionLibrary
        let catalog: AgentCatalog
        var repo: URL { directory.appending(path: "repo") }
        var trees: URL { directory.appending(path: "trees") }

        @MainActor init() async throws {
            library = SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite"))
            let defaults = try #require(UserDefaults(suiteName: suite))
            catalog = AgentCatalog(
                registry: AgentRegistry.Client(cacheDirectory: directory) { _ in .init(status: 404, data: Data()) },
                installer: AgentInstaller(root: directory.appending(path: "Agents"), download: { _, _ in }),
                defaults: defaults,
                environment: { _ in [:] },
                probe: { _ in throw AgentProbe.Failure.timedOut(seconds: 20) },
                checkNode: { _ in throw NodeRuntime.Failure.missingNode }
            )
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try await git(["init", "-q", "-b", "main"], in: repo)
            try await git(["commit", "-q", "--allow-empty", "-m", "Initial"], in: repo)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults().removePersistentDomain(forName: suite)
        }

        func mock(_ arguments: [String] = []) throws -> AgentInstallRecord {
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            return AgentInstallRecord(name: "Mock", executable: binary.path, arguments: arguments)
        }

        func choice(_ agent: AgentInstallRecord) -> AgentCatalog.Choice {
            .custom(.init(executable: agent.executable, arguments: agent.arguments))
        }

        @MainActor func start(_ agent: AgentInstallRecord, hints: [ACP.ConfigOption]) async -> LiveSession {
            let owner = LiveSession(library: library)
            owner.environment = { (ProcessInfo.processInfo.environment, nil) }
            owner.catalog = catalog
            await owner.start(
                directory: repo,
                agent: agent,
                worktreesRoot: trees,
                initialPrompt: .init(text: "hello"),
                configHints: hints
            )
            return owner
        }

        /// The started session as history replays it.
        @MainActor func history(of owner: LiveSession) async throws -> [ACP.ConfigOption] {
            let id = try #require(owner.controller?.session.id)
            return try await SessionController.history(id: id, store: library.store()).transcript.configOptions
        }

        @MainActor func expectNoSessionWorktree(_ owner: LiveSession) async throws {
            let list = try await git(["worktree", "list", "--porcelain"], in: repo)
            #expect(!list.contains(trees.lastPathComponent))
            #expect(try await git(["branch", "--format=%(refname:short)"], in: repo) == "main")
            let directory = try #require(owner.controller?.session.workingDirectory)
            #expect(directory.hasPrefix(trees.path) && !FileManager.default.fileExists(atPath: directory))
        }
    }

    /// MockAgent's model option (`small`, `large`) with `value` as the hint.
    private func model(_ value: String) -> ACP.ConfigOption {
        .init(
            id: "model",
            name: "Model",
            category: .model,
            value: .select(
                currentValue: value,
                options: .flat([.init(value: "small", name: "Small"), .init(value: "large", name: "Large")])
            )
        )
    }

    /// MockAgent's legacy modes (`ask`, `code`), as the adapter shows them, with `value` as the hint.
    private func mode(_ value: String) -> ACP.ConfigOption {
        .init(
            id: ACP.V1.AgentConnectionAdapter.modeOptionID,
            name: "Mode",
            category: .mode,
            value: .select(
                currentValue: value,
                options: .flat([.init(value: "ask", name: "Ask"), .init(value: "code", name: "Code")])
            )
        )
    }

    /// MockAgent's effort option (`--effort`; `low`, `medium`, `high`) with `value` as the hint; `max` is not offered.
    private func effort(_ value: String) -> ACP.ConfigOption {
        let choices = ["low", "medium", "high", "max"].map { ACP.ConfigSelectOption(value: $0, name: $0.capitalized) }
        return .init(
            id: "effort",
            name: "Effort",
            category: .thoughtLevel,
            value: .select(currentValue: value, options: .flat(choices))
        )
    }

    private func current(_ id: ACP.ConfigOptionID, in options: [ACP.ConfigOption]) -> String? {
        guard case .select(let value, _) = options.first(where: { $0.id == id })?.value else { return nil }
        return value
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func theModelHintIsAppliedBeforeTheRecordAndCached() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let agent = try fixture.mock()
        let owner = await fixture.start(agent, hints: [model("large")])
        let controller = try #require(owner.controller)
        #expect(owner.errorMessage == nil)
        #expect(current("model", in: controller.transcript.configOptions) == "large")
        // The mode was not picked, so the agent's own stays.
        #expect(current(ACP.V1.AgentConnectionAdapter.modeOptionID, in: controller.transcript.configOptions) == "ask")
        let history = try await fixture.history(of: owner)
        #expect(current("model", in: history) == "large")
        let cached = try #require(fixture.catalog.configHints[fixture.choice(agent)])
        #expect(current("model", in: cached) == "large")
        #expect(cached.count == 2)
        await owner.close()
    }

    @Test func theEffortHintIsAppliedWithTheModelAndCached() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let agent = try fixture.mock(["--effort"])
        // Both are changed, one at a time: the model's response lists the old effort, and the effort's the new model.
        let owner = await fixture.start(agent, hints: [model("large"), effort("high")])
        let controller = try #require(owner.controller)
        #expect(owner.errorMessage == nil)
        let cached = try #require(fixture.catalog.configHints[fixture.choice(agent)])
        for options in [controller.transcript.configOptions, try await fixture.history(of: owner), cached] {
            #expect(current("model", in: options) == "large")
            #expect(current("effort", in: options) == "high")
        }
        #expect(cached.count == 3)
        await owner.close()
    }

    @Test func anEffortTheAgentNoLongerOffersFailsTheStart() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let agent = try fixture.mock(["--effort"])
        let owner = await fixture.start(agent, hints: [model("large"), effort("max")])
        #expect(owner.errorMessage == "The agent does not offer “Max” any more.")
        #expect(owner.initialPrompt == PromptDraft(text: "hello"))
        let id = try #require(owner.controller?.session.id)
        #expect(try await fixture.library.store().session(id: id) == nil)
        try await fixture.expectNoSessionWorktree(owner)
        // The agent's list becomes the hint, with the model it confirmed before the effort was refused.
        let cached = try #require(fixture.catalog.configHints[fixture.choice(agent)])
        #expect(current("model", in: cached) == "large" && current("effort", in: cached) == "medium")
        await owner.close()
    }

    @Test func aPickedModeIsAppliedInTheAgentsOrderAndItsNotificationIsSuperseded() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // MockAgent notifies the mode before answering; that notification still lists the old model.
        let owner = await fixture.start(try fixture.mock(), hints: [model("large"), mode("code")])
        let controller = try #require(owner.controller)
        try await waitUntil { controller.transcript.items.contains { $0.message?.role == .user } }
        let modeID = ACP.V1.AgentConnectionAdapter.modeOptionID
        for options in [controller.transcript.configOptions, try await fixture.history(of: owner)] {
            #expect(current(modeID, in: options) == "code")
            #expect(current("model", in: options) == "large")
        }
        await owner.close()
    }

    @Test func anEqualValueSendsNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // The agent refuses every change, so a start that sent one would fail.
        let owner = await fixture.start(try fixture.mock(["--reject-config"]), hints: [model("small"), mode("ask")])
        #expect(owner.errorMessage == nil)
        #expect(owner.controller?.status == .idle || owner.controller?.status == .running)
        await owner.close()
    }

    @Test func aRefusedHintReturnsTheDraftWithoutARecordOrWorktree() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let agent = try fixture.mock(["--reject-config"])
        let owner = await fixture.start(agent, hints: [model("large")])
        #expect(owner.errorMessage == "The agent did not accept “Large”: Config changes are disabled")
        #expect(owner.initialPrompt == PromptDraft(text: "hello"))
        #expect(!owner.isLive)
        let id = try #require(owner.controller?.session.id)
        #expect(try await fixture.library.store().session(id: id) == nil)
        try await fixture.expectNoSessionWorktree(owner)
        // The list the agent reported becomes the hint, so the next Send works.
        let cached = try #require(fixture.catalog.configHints[fixture.choice(agent)])
        #expect(current("model", in: cached) == "small")
        await owner.close()
    }

    @Test func aHintTheAgentNoLongerOffersFailsTheStart() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let agent = try fixture.mock(["--no-config"])
        fixture.catalog.rememberHints([model("large")], for: fixture.choice(agent))
        let owner = await fixture.start(agent, hints: [model("large")])
        #expect(owner.errorMessage == "The agent does not offer “Large” any more.")
        let id = try #require(owner.controller?.session.id)
        #expect(try await fixture.library.store().session(id: id) == nil)
        try await fixture.expectNoSessionWorktree(owner)
        #expect(fixture.catalog.configHints[fixture.choice(agent)] == nil)
        await owner.close()
    }

    @Test func anAgentWithoutConfigOptionsStartsWithoutHints() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let agent = try fixture.mock(["--no-config"])
        let owner = await fixture.start(agent, hints: [])
        let controller = try #require(owner.controller)
        #expect(owner.errorMessage == nil)
        #expect(controller.transcript.configOptions.isEmpty)
        #expect(fixture.catalog.configHints.isEmpty)
        await owner.close()
    }

    @Test func aChangeInTheSessionUpdatesTheCache() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let agent = try fixture.mock()
        let owner = await fixture.start(agent, hints: [])
        let controller = try #require(owner.controller)
        try await waitUntil { controller.status == .idle && controller.completedTurns > 0 }
        #expect(current("model", in: fixture.catalog.configHints[fixture.choice(agent)] ?? []) == "small")
        try await controller.setConfigOption("model", to: .select("large"))
        #expect(current("model", in: fixture.catalog.configHints[fixture.choice(agent)] ?? []) == "large")
        await owner.close()
    }
}

@discardableResult private func git(_ arguments: [String], in directory: URL) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(
                with: Result {
                    let process = Process()
                    process.executableURL = URL(filePath: "/usr/bin/git")
                    process.currentDirectoryURL = directory
                    process.arguments =
                        [
                            "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c",
                            "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                        ] + arguments
                    process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = output
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
                }
            )
        }
    }
}
