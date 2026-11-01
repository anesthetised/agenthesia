import AppKit
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import AgentRuntime
@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// The draft screen's model: defaults, Send, and the draft coming back after a failed or cancelled start (ADR-0040).
@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionDraftTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "session-draft-\(UUID())")
        let sessions: SessionManager
        let model: SessionWindowModel

        @MainActor init(catalog: AgentCatalog? = nil) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sessions = SessionManager(
                library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")),
                worktreesRoot: directory.appending(path: "trees")
            )
            sessions.environment = { (ProcessInfo.processInfo.environment, nil) }
            model = SessionWindowModel(sessions: sessions, catalog: catalog)
        }

        @MainActor func remove() async {
            model.close()
            await sessions.closeAll()
            try? FileManager.default.removeItem(at: directory)
        }

        func mock(_ arguments: [String] = []) throws -> AgentCatalog.Choice {
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            return .custom(.init(executable: binary.path, arguments: arguments))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func theDraftDefaultsToTheNewestProjectAndAnEmptyDraftStartsNothing() async throws {
        let fixture = try Fixture()
        let store = try await fixture.sessions.library.store()
        let agent = AgentInstallRecord(name: "Test", executable: "unused")
        try await store.createAgentInstall(agent)
        var projects: [ProjectRecord] = []
        for (index, name) in ["Older", "Newer"].enumerated() {
            let project = ProjectRecord(name: name, rootPath: fixture.directory.appending(path: name).path)
            try await store.createProject(project)
            try await store.createSession(
                SessionRecord(
                    projectID: project.id,
                    agentInstallID: agent.id,
                    workingDirectory: project.rootPath,
                    createdAt: Date(timeIntervalSince1970: Double(index))
                )
            )
            projects.append(project)
        }
        let model = fixture.model
        await model.refresh()
        #expect(model.recentProjects.map(\.name) == ["Newer", "Older"])
        #expect(model.selectedDirectory?.path(percentEncoded: false).hasSuffix("/Newer/") == true)
        model.draftDirectory = URL(filePath: projects[0].rootPath)
        #expect(model.selectedDirectory == URL(filePath: projects[0].rootPath))
        // Without a catalog only a custom command can start a session.
        #expect(model.selectedAgent == nil && !model.canStartDraft)
        model.draftAgent = try fixture.mock()
        #expect(model.selectedAgent == model.draftAgent)
        #expect(!model.canStartDraft)
        model.draft.text = " \n"
        model.startDraft()
        #expect(model.owner == nil && fixture.sessions.owners.isEmpty && model.showingSetup)
        model.draft.text = "hello"
        #expect(model.canStartDraft)
        await fixture.remove()
    }

    @Test func sendStartsTheSessionWithTheDraftAndClearsIt() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let file = fixture.directory.appending(path: "notes.txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        model.draftDirectory = fixture.directory
        model.draftAgent = try fixture.mock()
        model.draft = PromptDraft(text: "hello", attachments: [file])
        model.startDraft()
        let owner = try #require(model.owner)
        #expect(!model.showingSetup && model.draft.isEmpty && model.draftError == nil)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        try await waitUntil { controller.status == .idle && controller.transcript.items.count > 1 }
        let sent = controller.transcript.items.compactMap(\.message).first { $0.role == .user }
        #expect(sent?.content.count == 2)
        #expect(model.abandonedStart == nil)
        await fixture.remove()
    }

    @Test func aFailedStartReturnsTheDraftWithItsError() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let draft = PromptDraft(text: "hello", attachments: [fixture.directory])
        model.draftDirectory = fixture.directory
        model.draftAgent = .custom(.init(executable: "/does-not-exist", arguments: []))
        model.draft = draft
        model.startDraft()
        let owner = try #require(model.owner)
        await owner.startup?.value
        #expect(model.abandonedStart === owner)
        await model.returnToDraft()
        #expect(model.showingSetup && model.owner == nil)
        #expect(model.draft == draft)
        #expect(model.draftError?.contains("does-not-exist") == true)
        #expect(model.draftAgent == .custom(.init(executable: "/does-not-exist", arguments: [])))
        // The session was not started, so the sidebar does not list it.
        #expect(fixture.sessions.owners.isEmpty)
        #expect(model.abandonedStart == nil)
        await fixture.remove()
    }

    @Test func cancellingTheStartAtSignInReturnsTheDraft() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let signInFile = fixture.directory.appending(path: "signed-in").path(percentEncoded: false)
        model.draftDirectory = fixture.directory
        model.draftAgent = try fixture.mock(["--auth", "--auth-file", signInFile])
        model.draft = PromptDraft(text: "hello")
        model.startDraft()
        let owner = try #require(model.owner)
        await owner.startup?.value
        #expect(model.signIn != nil)
        #expect(model.abandonedStart == nil)
        await model.endSession()
        #expect(model.abandonedStart === owner)
        await model.returnToDraft()
        #expect(model.showingSetup && model.draft == PromptDraft(text: "hello"))
        #expect(model.draftError == nil)
        #expect(fixture.sessions.owners.isEmpty)
        await fixture.remove()
    }

    @Test func onlyAStartedSessionRemembersItsAgentAndPickingAnotherClearsTheError() async throws {
        let suite = "session-draft-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = AgentCatalog(
            registry: AgentRegistry.Client(cacheDirectory: root) { _ in .init(status: 404, data: Data()) },
            installer: AgentInstaller(root: root.appending(path: "Agents"), download: { _, _ in }),
            defaults: defaults,
            environment: { _ in [:] },
            probe: { _ in throw AgentProbe.Failure.timedOut(seconds: 20) },
            checkNode: { _ in throw NodeRuntime.Failure.missingNode }
        )
        let fixture = try Fixture(catalog: catalog)
        let started = try fixture.mock()
        let model = fixture.model
        model.draftDirectory = fixture.directory
        model.draftAgent = started
        model.draft = PromptDraft(text: "hello")
        model.startDraft()
        await model.owner?.startup?.value
        #expect(catalog.lastChoice == started)
        // A second window's start fails: the agent that started a session stays the default.
        let other = SessionWindowModel(sessions: fixture.sessions, catalog: catalog)
        let missing = AgentCatalog.Choice.custom(.init(executable: "/does-not-exist", arguments: []))
        other.draftDirectory = fixture.directory
        other.draftAgent = missing
        other.draft = PromptDraft(text: "hello")
        other.startDraft()
        await other.owner?.startup?.value
        await other.returnToDraft()
        #expect(catalog.lastChoice == started && other.draftError != nil)
        other.draftAgent = started
        #expect(other.draftError == nil)
        other.close()
        await fixture.remove()
    }

    @Test func theWindowShowsTheDraftAgainAfterAFailedStart() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        _ = NSApplication.shared
        let host = NSHostingView(rootView: RootView(model: model))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        // The draft's editor is shown without a session.
        #expect(!views(NSTextView.self, in: host).filter(\.isEditable).isEmpty)
        model.draftDirectory = fixture.directory
        model.draftAgent = .custom(.init(executable: "/does-not-exist", arguments: []))
        model.draft = PromptDraft(text: "hello")
        model.startDraft()
        #expect(!model.showingSetup)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return model.showingSetup
        }
        #expect(model.draft == PromptDraft(text: "hello") && model.draftError != nil)
        await fixture.remove()
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
}
