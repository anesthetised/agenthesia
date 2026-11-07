import ACP
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

    @Test func newSessionInProjectOpensTheDraftWithThatProject() async throws {
        let fixture = try Fixture()
        let store = try await fixture.sessions.library.store()
        let agent = AgentInstallRecord(name: "Test", executable: "unused")
        try await store.createAgentInstall(agent)
        var records: [SessionRecord] = []
        for (index, name) in ["Older", "Newer"].enumerated() {
            let project = ProjectRecord(name: name, rootPath: fixture.directory.appending(path: name).path)
            try await store.createProject(project)
            let record = SessionRecord(
                projectID: project.id,
                agentInstallID: agent.id,
                workingDirectory: project.rootPath,
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
            try await store.createSession(record)
            records.append(record)
        }
        let model = fixture.model
        await model.refresh()
        await model.showHistory(records[1])
        #expect(!model.showingSetup)
        #expect(model.windowTitle == records[1].title ?? "New Session" && model.windowSubtitle == "Newer")
        model.draft.text = "keep me"
        // The row of the older session names its project, and the newest one is the draft's default.
        let row = try #require(
            model.sidebar.sections.flatMap(\.rows).first { $0.id == AnyHashable(records[0].id) }
        )
        let project = try #require(row.project)
        model.newSession(in: project)
        #expect(model.showingSetup && model.sidebarSelection == nil)
        #expect(model.selectedDirectory == URL(filePath: project.rootPath, directoryHint: .isDirectory))
        #expect(project.name == "Older" && model.draft.text == "keep me")
        // The previous session stays displayed behind the draft, but the window does not name it.
        #expect(model.windowTitle == "New Session" && model.windowSubtitle.isEmpty)
        await fixture.remove()
    }

    /// Two live MockAgent sessions in one window, both idle; the second is displayed.
    private func twoSessions(_ fixture: Fixture) async throws -> (first: LiveSession, second: LiveSession) {
        let model = fixture.model
        model.draftDirectory = fixture.directory
        model.draftAgent = try fixture.mock()
        var owners: [LiveSession] = []
        for text in ["first", "second"] {
            model.draft = PromptDraft(text: text)
            model.showingSetup = true
            model.startDraft()
            let owner = try #require(model.owner)
            await owner.startup?.value
            let controller = try #require(owner.controller)
            try await waitUntil { controller.status == .idle && controller.transcript.items.count > 1 }
            owners.append(owner)
        }
        return (owners[0], owners[1])
    }

    @Test func eachSessionKeepsItsComposerDraft() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let (first, second) = try await twoSessions(fixture)
        let file = fixture.directory.appending(path: "notes.txt")

        model.show(first)
        #expect(model.composer == ComposerDraft())
        model.composer.message = PromptDraft(text: "for the first", attachments: [file])
        model.show(second)
        #expect(model.composer == ComposerDraft())
        model.composer.message.text = "for the second"
        model.show(first)
        #expect(model.composer.message == PromptDraft(text: "for the first", attachments: [file]))
        model.show(second)
        #expect(model.composer.message.text == "for the second")

        // The window's draft for a new session is separate, and an emptied composer is not kept.
        model.showingSetup = true
        #expect(model.draft.isEmpty)
        model.show(second)
        model.composer.message.text = ""
        #expect(model.composerDrafts.count == 1)
        await fixture.remove()
    }

    @Test func aQueueEditSurvivesSwitchingUnlessItsMessageWasSent() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let (first, second) = try await twoSessions(fixture)
        model.show(first)
        let controller = try #require(first.controller)
        // The turn waits for the permission answer, so the next message stays queued.
        #expect(await first.submit("/write note.txt hello", attachments: [], intent: .whenReady))
        try await waitUntil { controller.status == .running && controller.pendingPermissions.isEmpty == false }
        #expect(await first.submit("queued", attachments: [], intent: .whenReady))
        let entry = try #require(controller.queuedPrompts.first)

        model.composer.message.text = "typed"
        model.composer.edit(entry)
        #expect(model.composer.message.text == "queued" && model.composer.editingQueueID == entry.id)
        model.show(second)
        model.dropStaleQueueEdit()
        model.show(first)
        model.dropStaleQueueEdit()
        #expect(model.composer.message.text == "queued" && model.composer.editingQueueID == entry.id)

        try await controller.removeQueuedPrompt(entry.id)
        model.show(second)
        model.show(first)
        model.dropStaleQueueEdit()
        #expect(model.composer.message.text == "typed" && model.composer.editingQueueID == nil)
        await fixture.remove()
    }

    @Test func theComposerShowsTheDisplayedSessionsDraftAndSendingClearsOnlyThat() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let (first, second) = try await twoSessions(fixture)
        model.show(first)
        _ = NSApplication.shared
        let view = NSHostingView(rootView: RootView(model: model))
        let window = OffscreenWindow(size: .init(width: 1000, height: 700))
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        func composer() -> NSTextView? {
            func find(_ view: NSView) -> NSTextView? {
                if let text = view as? FileTextView { return text }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(view)
        }
        func showing(_ text: String) async throws {
            try await waitUntil { composer()?.string == text }
        }

        try await waitUntil { composer() != nil }
        try #require(composer()).insertText("typed in the first", replacementRange: NSRange(location: 0, length: 0))
        #expect(model.composer.message.text == "typed in the first")
        model.show(second)
        try await showing("")
        try #require(composer()).insertText("typed in the second", replacementRange: NSRange(location: 0, length: 0))
        model.show(first)
        try await showing("typed in the first")

        // Return sends the draft of the session shown; the other session's draft stays.
        let controller = try #require(first.controller)
        let messages = controller.transcript.items.count
        try #require(composer()).doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await waitUntil { controller.transcript.items.count > messages }
        try await showing("")
        #expect(model.composerDrafts[controller.session.id] == nil)
        model.show(second)
        try await showing("typed in the second")
        await fixture.remove()
    }

    @Test func theFindBarAppearsAndAStepSelectsTheMatchInTheTranscript() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let (first, _) = try await twoSessions(fixture)
        model.show(first)
        _ = NSApplication.shared
        let view = NSHostingView(rootView: RootView(model: model))
        let window = OffscreenWindow(size: .init(width: 1000, height: 700))
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        func table() -> NSTableView? {
            func find(_ view: NSView) -> NSTableView? {
                if let table = view as? TranscriptTableView { return table }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(view)
        }
        try await waitUntil { (table()?.numberOfRows ?? 0) > 1 }
        model.openFind()
        model.find.query = "first"
        model.findNext()
        try await waitUntil { table()?.selectedRowIndexes.isEmpty == false }
        await fixture.remove()
    }

    @Test func theWindowFindsInTheDisplayedSessionAndForgetsOnClose() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        #expect(!model.canFind)
        let (first, second) = try await twoSessions(fixture)
        model.show(first)
        #expect(model.canFind)
        model.openFind()
        model.find.query = "first"
        model.updateFindMatches()
        #expect(model.find.matches.isEmpty == false)
        model.findNext()
        let item = try #require(model.find.reveal?.item)
        #expect(model.find.current == model.find.matches.firstIndex(of: item))
        // Another session is searched on its own.
        model.show(second)
        model.updateFindMatches()
        #expect(model.find.status == "No matches")
        model.closeFind()
        #expect(!model.find.isOpen && model.find.query.isEmpty && model.find.reveal == nil)
        model.showingSetup = true
        #expect(!model.canFind)
        await fixture.remove()
    }

    @Test func jumpToLatestNeedsATranscriptAwayFromItsEnd() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        model.endPosition = .scrolledUp
        model.jumpToLatest()
        #expect(!model.canJumpToLatest && model.jumpRequests == 0)
        let (first, _) = try await twoSessions(fixture)
        model.show(first)
        // At the end, there is nothing to jump to.
        model.endPosition = .following
        #expect(!model.canJumpToLatest)
        model.jumpToLatest()
        #expect(model.jumpRequests == 0)
        for position in [EndPosition.scrolledUp, .newBelow] {
            model.endPosition = position
            #expect(model.canJumpToLatest)
            model.jumpToLatest()
        }
        #expect(model.jumpRequests == 2)
        model.showingSetup = true
        #expect(!model.canJumpToLatest)
        await fixture.remove()
    }

    @Test func aReplyWhileScrolledUpShowsTheCapsuleAndTheJumpFollowsTheEndAgain() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let (first, _) = try await twoSessions(fixture)
        model.show(first)
        _ = NSApplication.shared
        let view = NSHostingView(rootView: RootView(model: model))
        let window = OffscreenWindow(size: .init(width: 1000, height: 700), drivesDisplayLink: true)
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        func table() -> TranscriptTableView? {
            func find(_ view: NSView) -> TranscriptTableView? {
                if let table = view as? TranscriptTableView { return table }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(view)
        }
        func atEnd() -> Bool {
            guard let table = table(), let clip = table.enclosingScrollView?.contentView else { return false }
            return TranscriptTableController.followsBottom(documentHeight: table.frame.height, visibleRect: clip.bounds)
        }
        let controller = try #require(first.controller)
        let long = (1...60).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        try await controller.submit([.text(.init(text: long))])
        try await waitUntil { controller.status == .idle && table().map { $0.frame.height > 900 } == true && atEnd() }
        #expect(model.endPosition == .following && !model.canJumpToLatest)

        // Scrolling up alone leaves the capsule out; the reader may still jump.
        let scroll = try #require(table()?.enclosingScrollView)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil { model.endPosition == .scrolledUp }
        #expect(model.canJumpToLatest)

        // A reply puts the capsule up, and the jump, as ⌥⌘↓ and the capsule's click ask for it, follows the end.
        let items = controller.transcript.items.count
        try await controller.submit([.text(.init(text: "another"))])
        try await waitUntil { controller.transcript.items.count > items && controller.status == .idle }
        try await waitUntil { model.endPosition == .newBelow }
        #expect(!atEnd())
        model.jumpToLatest()
        try await waitUntil { model.endPosition == .following && atEnd() }
        #expect(!model.canJumpToLatest)
        await fixture.remove()
    }

    @Test func focusComposerNeedsTheComposerCardAndCountsRequests() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        model.focusComposer()
        #expect(!model.canFocusComposer && model.composerFocusRequests == 0)
        let (first, _) = try await twoSessions(fixture)
        model.show(first)
        #expect(model.canFocusComposer)
        model.focusComposer()
        model.focusComposer()
        #expect(model.composerFocusRequests == 2)
        model.showingSetup = true
        #expect(!model.canFocusComposer)
        model.focusComposer()
        #expect(model.composerFocusRequests == 2)
        await fixture.remove()
    }

    @Test func focusComposerMovesKeyboardFocusBackToTheText() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let (first, _) = try await twoSessions(fixture)
        model.show(first)
        _ = NSApplication.shared
        let view = NSHostingView(rootView: RootView(model: model))
        let window = OffscreenWindow(size: .init(width: 1000, height: 700))
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        func composer() -> NSTextView? {
            func find(_ view: NSView) -> NSTextView? {
                if let text = view as? FileTextView { return text }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(view)
        }
        try await waitUntil { composer() != nil }
        let text = try #require(composer())
        window.makeFirstResponder(nil)
        #expect(window.firstResponder !== text)
        model.focusComposer()
        try await waitUntil { window.firstResponder === text }
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

    @Test func aFailedStartBringsBackThePicksAndDropsOnesTheAgentNoLongerOffers() async throws {
        let (catalog, cleanUp) = try isolatedCatalog()
        defer { cleanUp() }
        let fixture = try Fixture(catalog: catalog)
        fixture.sessions.catalog = catalog
        let model = fixture.model
        let modeID = ACP.V1.AgentConnectionAdapter.modeOptionID
        let options = [
            selectOption(modeID, .mode, "ask", ["ask", "code"]),
            selectOption("model", .model, "large", ["small", "large"]),
        ]
        // The executable is missing, so the start fails before any hint is applied and the cache stays as it was.
        let missing = AgentCatalog.Choice.custom(.init(executable: "/does-not-exist", arguments: []))
        catalog.rememberHints(options, for: missing)
        model.draftDirectory = fixture.directory
        model.draftAgent = missing
        model.draft = PromptDraft(text: "hello")
        model.draftConfig = [modeID: "code", "model": "small"]
        model.startDraft()
        #expect(model.draftConfig.isEmpty)
        let owner = try #require(model.owner)
        await owner.startup?.value
        await model.returnToDraft()
        #expect(model.draft == PromptDraft(text: "hello"))
        #expect(model.draftConfig == [modeID: "code", "model": "small"])
        #expect(model.draftHints.map(\.id) == [modeID, "model"])

        // The agent says it does not offer the picked mode any more: the pick is dropped and the next Send works.
        let agent = try fixture.mock(["--no-config"])
        catalog.rememberHints(options, for: agent)
        model.draftAgent = agent
        model.draftConfig = [modeID: "code"]
        model.startDraft()
        let stale = try #require(model.owner)
        await stale.startup?.value
        #expect(stale.errorMessage?.contains("any more") == true)
        await model.returnToDraft()
        #expect(model.draftConfig.isEmpty && model.draftHints.isEmpty)
        #expect(model.draftError?.contains("any more") == true)
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

    /// A catalog with no registry and no installed agents, on a throwaway defaults suite.
    private func isolatedCatalog() throws -> (catalog: AgentCatalog, cleanUp: () -> Void) {
        let suite = "session-draft-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        let catalog = AgentCatalog(
            registry: AgentRegistry.Client(cacheDirectory: root) { _ in .init(status: 404, data: Data()) },
            installer: AgentInstaller(root: root.appending(path: "Agents"), download: { _, _ in }),
            defaults: defaults,
            environment: { _ in [:] },
            probe: { _ in throw AgentProbe.Failure.timedOut(seconds: 20) },
            checkNode: { _ in throw NodeRuntime.Failure.missingNode }
        )
        return (
            catalog,
            {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
        )
    }

    private func selectOption(
        _ id: String,
        _ category: ACP.ConfigOptionCategory,
        _ value: String,
        _ values: [String]
    ) -> ACP.ConfigOption {
        .init(
            id: id,
            name: id,
            category: category,
            value: .select(currentValue: value, options: .flat(values.map { .init(value: $0, name: $0) }))
        )
    }

    @Test func sendAppliesTheCachedModelAndAModeOnlyWhenPickedInTheDraft() async throws {
        let (catalog, cleanUp) = try isolatedCatalog()
        defer { cleanUp() }
        let fixture = try Fixture(catalog: catalog)
        fixture.sessions.catalog = catalog
        let agent = try fixture.mock()
        let modeID = ACP.V1.AgentConnectionAdapter.modeOptionID
        // An earlier session ended in code mode with the large model.
        catalog.rememberHints(
            [
                selectOption(modeID, .mode, "code", ["ask", "code"]),
                selectOption("model", .model, "large", ["small", "large"]),
            ],
            for: agent
        )
        func send() async throws -> [ACP.ConfigOption] {
            let model = fixture.model
            model.draftDirectory = fixture.directory
            model.draft = PromptDraft(text: "hello")
            model.startDraft()
            let owner = try #require(model.owner)
            await owner.startup?.value
            #expect(owner.errorMessage == nil)
            #expect(model.draftConfig.isEmpty)
            return try #require(owner.controller).transcript.configOptions
        }
        func current(_ id: String, _ options: [ACP.ConfigOption]) -> String? {
            guard case .select(let value, _) = options.first(where: { $0.id == id })?.value else { return nil }
            return value
        }
        let model = fixture.model
        model.draftAgent = agent
        #expect(model.draftHints.map(\.id) == ["model"])
        let first = try await send()
        #expect(current(modeID, first) == "ask" && current("model", first) == "large")

        model.showingSetup = true
        model.draftAgent = agent
        model.draftConfig[modeID] = "code"
        #expect(model.draftHints.map(\.id) == [modeID, "model"])
        // Changing the agent resets what was picked.
        model.draftAgent = agent
        #expect(model.draftConfig.isEmpty)
        model.draftConfig[modeID] = "code"
        let second = try await send()
        #expect(current(modeID, second) == "code" && current("model", second) == "large")
        await fixture.remove()
    }

    @Test func pillsComeFromTheCacheAndNeverPromiseMoreThanSendApplies() throws {
        let (catalog, cleanUp) = try isolatedCatalog()
        defer { cleanUp() }
        let model = SessionWindowModel(
            sessions: SessionManager(library: SessionLibrary(databaseURL: URL(filePath: "/dev/null"))),
            catalog: catalog
        )
        let agent = AgentCatalog.Choice.custom(.init(executable: "agent", arguments: []))
        let other = AgentCatalog.Choice.custom(.init(executable: "other", arguments: []))
        model.draftAgent = agent
        // Without a cache there are no pills and nothing to apply.
        #expect(model.draftPills.isEmpty && model.draftHints.isEmpty)

        let effort = selectOption("effort", .thoughtLevel, "high", ["low", "high"])
        catalog.rememberHints(
            [
                selectOption("mode", .mode, "code", ["ask", "code"]),
                selectOption("model", .model, "large", ["small", "large"]), effort,
            ],
            for: agent
        )
        // Mode and model only; the mode reads Default mode and is not applied until picked, the model is.
        #expect(model.draftPills.map(\.id) == ["mode", "model"])
        #expect(model.draftPills.map { model.draftValue(of: $0) } == [nil, "large"])
        #expect(model.draftHints.map(\.id) == ["model"])

        // Each pill's value is what the hints carry.
        model.draftConfig = ["mode": "ask", "model": "small"]
        let values = model.draftHints.map { option -> String? in
            guard case .select(let value, _) = option.value else { return nil }
            return value
        }
        #expect(model.draftHints.map(\.id) == ["mode", "model"] && values == ["ask", "small"])
        #expect(model.draftPills.map { model.draftValue(of: $0) } == values)

        // A pick the agent does not offer is shown and applied as if never made.
        model.draftConfig = ["mode": "bypass", "model": "huge"]
        #expect(model.draftPills.map { model.draftValue(of: $0) } == [nil, "large"])
        #expect(model.draftHints.map(\.id) == ["model"])

        // Changing the agent resets the picks, and another agent has its own pills.
        model.draftConfig = ["mode": "ask"]
        model.draftAgent = other
        #expect(model.draftConfig.isEmpty && model.draftPills.isEmpty && model.draftHints.isEmpty)
        model.draftAgent = agent
        #expect(model.draftPills.map { model.draftValue(of: $0) } == [nil, "large"])
    }

    @Test func theDraftShowsThePillsFromTheCacheAndAModeReadsDefaultUntilPicked() async throws {
        let (catalog, cleanUp) = try isolatedCatalog()
        defer { cleanUp() }
        let fixture = try Fixture(catalog: catalog)
        let agent = try fixture.mock()
        let model = fixture.model
        model.draftDirectory = fixture.directory
        model.draftAgent = agent
        _ = NSApplication.shared
        let host = NSHostingView(rootView: RootView(model: model).frame(width: 900, height: 600))
        let window = OffscreenWindow(size: .init(width: 900, height: 600))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func titles() async throws -> [String] {
            try await Task.sleep(for: .milliseconds(100))
            for _ in 0..<30 { await Task.yield(); host.layoutSubtreeIfNeeded() }
            return popups(in: host).map { $0.accessibilityLabel() ?? "" }
        }
        #expect(model.showingSetup)
        // Without a cache only the project and the agent are there.
        #expect(try await titles().count == 2)

        catalog.rememberHints(
            [
                selectOption("mode", .mode, "code", ["ask", "code"]),
                selectOption("model", .model, "large", ["small", "large"]),
            ],
            for: agent
        )
        let shown = try await titles()
        #expect(shown.suffix(2) == ["Default mode", "large"])
        model.draftConfig["mode"] = "ask"
        #expect(try await titles().suffix(2) == ["ask", "large"])
        model.draftAgent = agent
        #expect(try await titles().suffix(2) == ["Default mode", "large"])
        await fixture.remove()
    }

    @Test func aPillIsWordedAsAHintAndNamesItsOption() throws {
        let option = selectOption("mode", .mode, "code", ["ask", "code"])
        guard case .select(_, let choices) = option.value else {
            Issue.record("not a select")
            return
        }
        let pill = ConfigSelectMenu(
            option: option,
            choices: choices,
            selected: nil,
            placeholder: "Default mode",
            note: SessionDraftView.hintNote
        ) { _ in }
        #expect(
            pill.accessibilityText == "mode: Default mode. Last used with this agent; confirmed when the session starts"
        )
        let live = ConfigSelectMenu(option: option, choices: choices, selected: "code") { _ in }
        #expect(live.accessibilityText == "mode: code")
    }

    private func popups(in view: NSView) -> [NSPopUpButton] {
        ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap(popups)
    }

    @Test func theWindowShowsTheDraftAgainAfterAFailedStart() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        _ = NSApplication.shared
        let host = NSHostingView(rootView: RootView(model: model))
        let window = OffscreenWindow(size: .init(width: 1000, height: 600))
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
