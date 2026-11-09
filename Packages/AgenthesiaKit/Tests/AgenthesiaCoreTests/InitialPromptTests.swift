import ACP
import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore

/// A session started from the draft holds its first message until it is idle (ADR-0040).
@MainActor @Suite(.timeLimit(.minutes(1))) struct InitialPromptTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "initial-prompt-\(UUID())")
        let library: SessionLibrary
        var project: URL { directory.appending(path: "project") }

        init() throws {
            library = SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite"))
            try FileManager.default.createDirectory(
                at: directory.appending(path: "project"),
                withIntermediateDirectories: true
            )
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func mock(_ arguments: [String] = []) throws -> AgentInstallRecord {
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            return AgentInstallRecord(name: "Mock", executable: binary.path, arguments: arguments)
        }

        @MainActor func owner() -> LiveSession {
            let owner = LiveSession(library: library)
            owner.environment = { (ProcessInfo.processInfo.environment, nil) }
            return owner
        }
    }

    /// Polls until the condition holds, failing after a few seconds instead of hanging the suite.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func userContent(_ controller: SessionController) -> [ACP.ContentBlock]? {
        controller.transcript.items.compactMap(\.message).first { $0.role == .user }?.content
    }

    @Test func theDraftIsSubmittedAtTheFirstIdleStateWithItsAttachments() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.project.appending(path: "notes.txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        let owner = fixture.owner()
        await owner.start(
            directory: fixture.project,
            agent: try fixture.mock(),
            initialPrompt: PromptDraft(text: "hello", attachments: [file])
        )
        let controller = try #require(owner.controller)
        #expect(owner.initialPrompt == nil)
        #expect(owner.errorMessage == nil)
        try await waitUntil { controller.status == .idle && controller.transcript.items.count > 1 }
        let content = try #require(userContent(controller))
        #expect(content.count == 2)
        guard case .text(let text) = content.first, case .resourceLink(let link) = content.last else {
            Issue.record("Unexpected content \(content)")
            return
        }
        #expect(text.text == "hello")
        #expect(link.uri == file.absoluteString)
        #expect(controller.transcript.items.last?.message?.text.hasPrefix("Echo: hello") == true)
        #expect(controller.queuedPrompts.isEmpty)
        await owner.close()
        // The prompt is part of the session's history like a typed one.
        let restored = try await SessionController.restore(id: controller.session.id, store: fixture.library.store())
        #expect(restored.transcript == controller.transcript)
    }

    @Test func theStartLineNamesWhereTheSessionWorksOnceItsPlaceIsKnown() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = fixture.owner()
        #expect(owner.startLine == nil)
        await owner.start(directory: fixture.project, agent: try fixture.mock(), initialPrompt: PromptDraft(text: "hi"))
        #expect(owner.startPlace == .projectFolder && owner.fetching == nil)
        #expect(owner.startLine == "Starting Mock in the project folder…")
        await owner.close()
    }

    @Test func aSessionThatNeedsSignInSubmitsTheDraftAfterSignIn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signInFile = fixture.directory.appending(path: "signed-in")
        let owner = fixture.owner()
        await owner.start(
            directory: fixture.project,
            agent: try fixture.mock(["--auth", "--auth-file", signInFile.path(percentEncoded: false)]),
            initialPrompt: PromptDraft(text: "hello")
        )
        #expect(owner.signIn != nil)
        #expect(owner.initialPrompt == PromptDraft(text: "hello"))
        let controller = try #require(owner.controller)
        #expect(userContent(controller) == nil)
        await owner.signIn(with: "mock-login")
        #expect(owner.signIn == nil)
        #expect(owner.initialPrompt == nil)
        try await waitUntil { controller.status == .idle && controller.transcript.items.count > 1 }
        #expect(userContent(controller) == [.init(text: "hello")])
        await owner.close()
    }

    @Test func aFailedStartKeepsTheDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = fixture.owner()
        let draft = PromptDraft(text: "hello", attachments: [fixture.project])
        await owner.start(
            directory: fixture.project,
            agent: AgentInstallRecord(name: "Missing", executable: "/does-not-exist"),
            initialPrompt: draft
        )
        #expect(owner.errorMessage != nil)
        #expect(!owner.isLive)
        #expect(owner.initialPrompt == draft)
        await owner.close()
        #expect(try await fixture.library.history().isEmpty)
    }

    @Test func cancellingTheStartKeepsTheDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = fixture.owner()
        let gate = AsyncStream<Void>.makeStream()
        // Startup waits for the login shell; closing then cancels it before the agent runs.
        owner.environment = {
            for await _ in gate.stream {}
            return (ProcessInfo.processInfo.environment, nil)
        }
        owner.begin(
            .new(directory: fixture.project, agent: try fixture.mock(), worktreesRoot: nil, additionalDirectories: []),
            initialPrompt: PromptDraft(text: "hello")
        )
        #expect(owner.isStarting)
        let closing = Task { await owner.close() }
        try await waitUntil { owner.isClosed }
        gate.continuation.finish()
        await closing.value
        #expect(!owner.isLive)
        #expect(owner.errorMessage == nil)
        #expect(owner.initialPrompt == PromptDraft(text: "hello"))
        #expect(owner.controller == nil)
        #expect(try await fixture.library.history().isEmpty)
    }

    @Test func theCheckoutNamesTheWorktreeBaseOrTheFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(await DraftCheckout.of(fixture.project) == .folder)
        #expect(DraftCheckout.folder.title == "Project folder")
        #expect(DraftCheckout.worktree(from: "main").title == "New worktree from main")
        #expect(DraftCheckout.worktree(from: "origin/main").title == "New worktree from origin/main")
        #expect(DraftCheckout.worktree(from: "main").help.contains("Uncommitted and untracked files are not copied"))
        #expect(!DraftCheckout.folder.help.isEmpty)
    }

    @Test func emptyDraftsHaveNothingToSend() {
        #expect(PromptDraft().isEmpty)
        #expect(PromptDraft(text: " \n").isEmpty)
        #expect(!PromptDraft(text: "hi").isEmpty)
        #expect(!PromptDraft(attachments: [URL(filePath: "/tmp")]).isEmpty)
    }

    @Test func projectsAreOrderedByTheirNewestSession() {
        let old = ProjectRecord(name: "Old", rootPath: "/old")
        let new = ProjectRecord(name: "New", rootPath: "/new")
        let unused = ProjectRecord(name: "Unused", rootPath: "/unused")
        let agent = UUID()
        func session(_ project: ProjectRecord, _ time: TimeInterval) -> SessionRecord {
            SessionRecord(
                projectID: project.id,
                agentInstallID: agent,
                workingDirectory: project.rootPath,
                createdAt: Date(timeIntervalSince1970: time)
            )
        }
        let scratch = ProjectRecord(name: "No project", rootPath: "/scratch")
        let history = [session(old, 1), session(new, 2), session(old, 0), session(scratch, 3)]
        #expect(
            ProjectRecord.recent([unused, old, new, scratch], history: history, scratchPath: "/scratch").map(\.name)
                == ["New", "Old", "Unused"]
        )
        #expect(
            ProjectRecord.recent([unused, old], history: [], scratchPath: "/scratch").map(\.name) == ["Unused", "Old"]
        )
    }
}
