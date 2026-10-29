import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite struct SessionWindowModelTests {
    private func manager(_ directory: URL) -> SessionManager {
        let manager = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        manager.environment = { (ProcessInfo.processInfo.environment, nil) }
        return manager
    }

    @Test func savedHistoryCanBeSelectedAndClosingPreventsNewLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = manager(directory)
        let store = try await sessions.library.store()
        let project = ProjectRecord(name: "Test", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Test", executable: "unused")
        let record = SessionRecord(
            projectID: project.id,
            agentInstallID: agent.id,
            agentSessionID: "saved",
            workingDirectory: directory.path
        )
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        try await store.createSession(record)
        let model = SessionWindowModel(sessions: sessions)
        await model.refresh()
        #expect(model.history == [record])
        await model.showHistory(record)
        #expect(model.displayed?.status == .readOnly)
        #expect(!model.isLoadingHistory)
        #expect(model.canContinue)
        // The configured agent does not exist; the failed owner stays listed as live, history keeps the record.
        model.continueRestored()
        #expect(model.restored == nil)
        let failed = try #require(model.owner)
        #expect(model.filesSession?.id == record.id)
        await failed.startup?.value
        #expect(failed.errorMessage?.contains("unused") == true)
        #expect(model.filesSession == nil)
        #expect(sessions.owners.map(\.id) == [failed.id])
        #expect(model.history == [record] && model.savedSessions.isEmpty)
        await model.showHistory(record)
        model.errorMessage = "Stale"
        model.showLive()
        #expect(model.errorMessage == nil)
        #expect(model.displayed == nil)
        #expect(model.canStart)
        model.close()
        #expect(!model.canStart)
        model.start(directory: directory, executable: "/does-not-exist", arguments: [])
        #expect(model.owner === failed)
        #expect(sessions.owners.count == 1)
    }

    private func mock(arguments: [String] = []) throws -> AgentInstallRecord {
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        return AgentInstallRecord(name: "Mock", executable: binary.path, arguments: arguments)
    }

    @Test func windowsShareLiveSessionsAndClosingOneKeepsThemRunning() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-shared-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = manager(directory)
        let first = SessionWindowModel(sessions: sessions)
        let second = SessionWindowModel(sessions: sessions)
        let agent = try mock()
        first.start(directory: directory, executable: agent.executable, arguments: [])
        let owner = try #require(first.owner)
        #expect(first.canStart)
        first.start(directory: directory, executable: agent.executable, arguments: [])
        let other = try #require(first.owner)
        #expect(other !== owner && sessions.owners.map(\.id) == [owner.id, other.id])
        await owner.startup?.value
        await other.startup?.value
        let record = try #require(owner.controller?.session)
        await second.refresh()
        #expect(second.history.count == 2 && second.savedSessions.isEmpty)
        // Selecting a live session from history shows its owner.
        await second.showHistory(record)
        #expect(second.owner === owner && second.restored == nil)
        #expect(second.displayed === owner.controller)
        first.close()
        #expect(owner.controller?.status == .idle && other.controller?.status == .idle)
        await sessions.end(owner)
        await second.refresh()
        #expect(second.savedSessions.map(\.id) == [record.id])
        await sessions.closeAll()
    }

    @Test func activationFillsALoneBlankWindowAndOtherwiseOpensTheSessionsWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-activation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = manager(directory)
        let owner = sessions.start(directory: directory, agent: try mock())
        await owner.startup?.value
        let record = try #require(owner.controller?.session)
        let target = WindowTarget.session(record.id)
        var opened: [WindowTarget] = []

        // The system makes a blank window to receive the URL when none is open.
        let blank = SessionWindowModel(sessions: sessions)
        await blank.activate(target, isBlank: true, windowCount: 1) { opened.append($0) }
        #expect(opened.isEmpty && blank.owner === owner && blank.target == target)

        // A window that already shows a session, or a form being filled in, is left alone.
        let busy = SessionWindowModel(sessions: sessions)
        await busy.activate(target, isBlank: false, windowCount: 1) { opened.append($0) }
        await blank.activate(target, isBlank: true, windowCount: 1) { opened.append($0) }
        // Several windows: raise or open the session's own window instead of repurposing this one.
        let other = SessionWindowModel(sessions: sessions)
        await other.activate(target, isBlank: true, windowCount: 3) { opened.append($0) }
        #expect(opened == [target, target, target])
        #expect(busy.target == .launch && other.target == .launch)

        // Neither the launch target nor a closed window opens anything.
        await other.activate(.launch, isBlank: true, windowCount: 1) { opened.append($0) }
        other.close()
        await other.activate(target, isBlank: true, windowCount: 1) { opened.append($0) }
        #expect(opened.count == 3 && other.target == .launch)
        await sessions.closeAll()
    }

    @Test func aWindowReportsTheSessionItShowsOnlyWhileAskedAndClosingClearsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-shown-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = manager(directory)
        let first = SessionWindowModel(sessions: sessions)
        let second = SessionWindowModel(sessions: sessions)
        let id = UUID()
        sessions.setShown(id, in: first)
        sessions.setShown(id, in: second)
        #expect(sessions.shownSessionIDs == [id])
        first.close()
        #expect(sessions.shownSessionIDs == [id])
        sessions.setShown(nil, in: second)
        #expect(sessions.shownSessionIDs.isEmpty)
    }

    @Test func sidebarFollowsTheManagerAndRefreshLoadsProjects() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-sidebar-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = manager(directory)
        let model = SessionWindowModel(sessions: sessions)
        let agent = try mock()
        model.start(directory: directory, executable: agent.executable, arguments: [])
        let owner = try #require(model.owner)
        #expect(model.sidebar.sections.map(\.kind) == [.working])
        #expect(model.sidebar.rows.first?.project == nil)
        await owner.startup?.value
        await model.refresh()
        #expect(model.projects.count == 1)
        #expect(model.sidebar.sections.map(\.kind) == [.working])
        #expect(model.sidebar.rows.first?.project?.id == model.projects.first?.id)
        await sessions.end(owner)
        await model.refresh()
        guard case .saved(let record)? = model.sidebar.rows.first?.source else {
            Issue.record("Expected the ended session to be saved")
            return
        }
        #expect(record.id == owner.sessionID)
    }

    @Test(arguments: [false, true])
    func establishedSessionsCanContinueAfterEndOrFailureCleanup(failed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = manager(directory)
        let model = SessionWindowModel(sessions: sessions)
        let agent = try mock(arguments: ["--reopen"])
        model.start(directory: directory, executable: agent.executable, arguments: agent.arguments)
        let owner = try #require(model.owner)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        let record = controller.session
        #expect(controller.status == .idle)
        await model.refresh()
        #expect(!model.canContinue)
        #expect(!model.savedSessions.contains { $0.id == record.id })
        try await controller.submit([.init(text: "write \(directory.appending(path: "not-written.txt").path) text")])
        while controller.pendingPermissions.isEmpty { await Task.yield() }
        try await controller.submit([.init(text: "retained")])
        try await controller.stop()
        while controller.status != .idle { await Task.yield() }
        if failed {
            await owner.send("exit")
            // Observe the real process-cleanup path, which changes failed to closed.
            while controller.status != .closed { await Task.yield() }
            #expect(owner.errorMessage != nil)
            #expect(sessions.owners.map(\.id) == [owner.id])
        } else {
            await sessions.end(owner)
            #expect(sessions.owners.isEmpty)
        }
        await model.refresh()
        #expect(controller.status == .closed)
        #expect(model.canContinue)
        #expect(model.savedSessions.contains { $0.id == record.id } == !failed)
        #expect(model.filesSession?.id == record.id)
        model.continueRestored()
        let continuing = try #require(model.owner)
        #expect(continuing !== owner)
        #expect(sessions.owners.map(\.id) == [continuing.id])
        // File browsing follows the session through the startup gap without a controller.
        var lostFiles = false
        let startup = Task { await continuing.startup?.value }
        while continuing.isStarting {
            if model.filesSession?.id != record.id { lostFiles = true }
            await Task.yield()
        }
        await startup.value
        #expect(!lostFiles)
        let continued = try #require(continuing.controller)
        #expect(continued.session.id == record.id)
        #expect(continued.status == .idle)
        #expect(continued.queuePaused)
        #expect(continued.queuedPrompts.map(\.text) == ["retained"])
        await sessions.closeAll()
    }

    @Test func startupFailuresAndHistoryWithoutRemoteIdentityCannotContinue() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-no-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = manager(directory)
        let model = SessionWindowModel(sessions: sessions)
        let signInFile = directory.appending(path: "signed-in").path(percentEncoded: false)
        for agent in [
            AgentInstallRecord(name: "Missing", executable: "/does-not-exist"),
            try mock(arguments: ["--auth", "--auth-file", signInFile]),
        ] {
            model.start(directory: directory, executable: agent.executable, arguments: agent.arguments)
            let owner = try #require(model.owner)
            await owner.startup?.value
            await model.refresh()
            // A failed start, or one waiting for sign-in (ADR-0033): neither has history yet.
            #expect((owner.errorMessage != nil) != (owner.signIn != nil))
            #expect(!model.canContinue)
            #expect(model.savedSessions.isEmpty)
            model.continueRestored()
            #expect(model.owner === owner)
            await sessions.end(owner)
        }
        let store = try await sessions.library.store()
        let project = ProjectRecord(name: "No remote session", rootPath: directory.appending(path: "other").path)
        let agent = try mock()
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        let record = SessionRecord(projectID: project.id, agentInstallID: agent.id, workingDirectory: directory.path)
        try await store.createSession(record)
        await model.showHistory(record)
        #expect(model.displayed?.status == .readOnly)
        #expect(!model.canContinue)
        model.close()
    }

    @Test func navigationFollowsSidebarAcrossProjectsSavedHistoryAndStartingOwners() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-navigation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = manager(directory)
        let model = SessionWindowModel(sessions: sessions)
        #expect(model.navigationTarget() == nil)
        #expect(model.sidebarSelection == nil)
        let store = try await sessions.library.store()
        let agent = try mock()
        try await store.createAgentInstall(agent)
        var records: [SessionRecord] = []
        for index in 0..<2 {
            let project = ProjectRecord(name: "Project \(index)", rootPath: directory.appending(path: "p\(index)").path)
            try await store.createProject(project)
            let record = SessionRecord(
                projectID: project.id,
                agentInstallID: agent.id,
                agentSessionID: "saved",
                workingDirectory: project.rootPath,
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
            try await store.createSession(record)
            records.append(record)
        }
        let starting = sessions.start(
            directory: directory,
            agent: AgentInstallRecord(name: "Missing", executable: "/missing")
        )
        await starting.startup?.value
        await model.refresh()
        #expect(model.navigationTarget()?.id == AnyHashable(starting.id))
        await model.navigate()
        #expect(model.owner === starting && !model.showingSetup)
        #expect(model.sidebarSelection == AnyHashable(starting.id))
        #expect(model.canEnd)
        await model.navigate()
        #expect(model.displayed?.session.id == records[1].id)
        #expect(!model.canEnd && !model.canStop && !model.canResumeQueue && model.canContinue)
        await model.navigate()
        #expect(model.displayed?.session.id == records[0].id)
        await model.navigate()
        #expect(model.owner === starting && model.restored == nil)
        await model.navigate(backward: true)
        #expect(model.displayed?.session.id == records[0].id)
        #expect(model.navigationTarget(needsInput: true) == nil)
        // A queued native selection cannot override a newer command selection.
        model.sidebarSelection = AnyHashable(records[1].id)
        model.show(starting)
        await Task.yield()
        #expect(model.owner === starting && model.restored == nil)
        model.showingSetup = true
        model.sidebarSelection = AnyHashable(starting.id)
        #expect(!model.showingSetup && model.owner === starting)
        model.sidebarSelection = AnyHashable(UUID())
        #expect(model.sidebarSelection == AnyHashable(starting.id))
        model.close()
        model.sidebarSelection = AnyHashable(records[0].id)
        #expect(model.sidebarSelection == nil)
        #expect(model.navigationTarget() == nil)
        await sessions.closeAll()
    }

    @Test func navigationVisitsNeedsYouBeforeWorkingWhateverTheStartOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-sections-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = manager(directory)
        let model = SessionWindowModel(sessions: sessions)
        let agent = try mock()
        let working = sessions.start(directory: directory, agent: agent)
        await working.startup?.value
        let workingID = try #require(working.sessionID)
        let failed = sessions.start(
            directory: directory,
            agent: AgentInstallRecord(name: "Missing", executable: "/missing")
        )
        await failed.startup?.value
        await model.refresh()
        #expect(model.sidebar.sections.map(\.kind) == [.needsYou, .working])
        #expect(model.navigationTarget()?.id == AnyHashable(failed.id))
        #expect(model.navigationTarget(backward: true)?.id == AnyHashable(workingID))
        model.show(failed)
        #expect(model.navigationTarget()?.id == AnyHashable(workingID))
        // Failed sessions are in Needs You, but only a session that waits for input is skipped to.
        #expect(model.navigationTarget(needsInput: true) == nil)
        await sessions.closeAll()
    }

    @Test func commandsAffectOnlyTheSelectedWindowAndSkipToInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-commands-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = manager(directory)
        let first = SessionWindowModel(sessions: sessions)
        let second = SessionWindowModel(sessions: sessions)
        let agent = try mock()
        first.start(directory: directory, executable: agent.executable, arguments: [])
        let owner = try #require(first.owner)
        second.start(directory: directory, executable: agent.executable, arguments: [])
        let other = try #require(second.owner)
        await owner.startup?.value
        await other.startup?.value
        await first.refresh()
        let controller = try #require(owner.controller)
        let turn = Task { await owner.send("write \(directory.appending(path: "unwritten.txt").path) text") }
        while controller.pendingPermissions.isEmpty { await Task.yield() }
        #expect(first.canStop && !second.canStop)
        await second.refresh()
        await second.navigate(needsInput: true)
        #expect(second.owner === owner)
        second.show(other)
        first.showingSetup = true
        #expect(!first.canStop && !first.canEnd && !first.canContinue)
        first.showingSetup = false
        await first.stop()
        await turn.value
        #expect(controller.pendingPermissions.isEmpty)
        #expect(controller.queuePaused && controller.queuedPrompts.isEmpty)
        #expect(first.canResumeQueue && !second.canResumeQueue)
        await first.resumeQueue()
        #expect(!controller.queuePaused)
        try await controller.submit([.init(text: "write \(directory.appending(path: "not-written.txt").path) text")])
        while controller.pendingPermissions.isEmpty { await Task.yield() }
        try await controller.submit([.init(text: "queued")])
        try await controller.stop()
        while controller.status != .idle { await Task.yield() }
        #expect(first.canResumeQueue && !second.canResumeQueue)
        await first.resumeQueue()
        #expect(!controller.queuePaused)
        await first.endSession()
        #expect(sessions.owners.map(\.id) == [other.id])
        #expect(second.owner === other && other.isLive)
        #expect(first.canContinue && !first.canEnd)
        await sessions.closeAll()
    }

    @Test func transcriptTableDoesNotRetainItsSource() {
        let table = TranscriptTableController()
        weak var retained: DemoSession?
        do {
            let source = DemoSession()
            retained = source
            table.update(source)
        }
        #expect(retained == nil)
    }

    @Test func successfulRefreshClearsPreviousFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try "obstruction".write(to: directory, atomically: true, encoding: .utf8)
        let model = SessionWindowModel(
            sessions: SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        )
        await model.refresh()
        #expect(model.errorMessage != nil)
        try FileManager.default.removeItem(at: directory)
        await model.refresh()
        #expect(model.errorMessage == nil)
        #expect(model.history.isEmpty)
    }

    @Test func launchInputExpandsHomeAndPreservesLiteralArguments() {
        let command = RootView.launchCommand(
            executable: " ~/bin/my agent \n",
            arguments: "--label\n  spaced value  \n \n\n--flag"
        )
        #expect(
            command.executable == FileManager.default.homeDirectoryForCurrentUser.appending(path: "bin/my agent").path
        )
        #expect(command.arguments == ["--label", "  spaced value  ", " ", "--flag"])
        #expect(RootView.launchCommand(executable: "agent", arguments: "").executable == "agent")
        #expect(RootView.launchCommand(executable: "/opt/my agent", arguments: "").executable == "/opt/my agent")
    }
}

@MainActor @Suite struct WindowTargetTests {
    @Test func targetsEncodeAndDecode() throws {
        let id = UUID()
        for target in [WindowTarget.launch, .session(id)] {
            let data = try JSONEncoder().encode(target)
            #expect(try JSONDecoder().decode(WindowTarget.self, from: data) == target)
        }
    }

    @Test func restoresSavedSessionReadOnlyAndFallsBackToLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-target-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        let store = try await sessions.library.store()
        let project = ProjectRecord(name: "Test", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Test", executable: "unused")
        let record = SessionRecord(
            projectID: project.id,
            agentInstallID: agent.id,
            agentSessionID: "saved",
            workingDirectory: directory.path
        )
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        try await store.createSession(record)

        let model = SessionWindowModel(sessions: sessions)
        #expect(model.target == .launch)
        await model.restore(.session(record.id))
        #expect(model.displayed?.status == .readOnly)
        #expect(model.target == .session(record.id))
        #expect(model.canContinue)

        let missing = SessionWindowModel(sessions: sessions)
        await missing.restore(.session(UUID()))
        #expect(missing.target == .launch && missing.showingSetup && missing.displayed == nil)
        let launch = SessionWindowModel(sessions: sessions)
        await launch.restore(.launch)
        #expect(launch.target == .launch)
        model.close()
        #expect(model.target == .launch)
    }
}

@MainActor @Suite struct NavigationTargetWindowTests {
    @Test func savedAndIdentifiedLiveSessionsHaveWindowTargets() throws {
        let record = SessionRecord(projectID: UUID(), agentInstallID: UUID(), workingDirectory: "/tmp")
        #expect(SessionWindowModel.NavigationTarget.saved(record).windowTarget == .session(record.id))
        let directory = FileManager.default.temporaryDirectory.appending(path: "nav-target-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        let starting = sessions.start(
            directory: directory,
            agent: AgentInstallRecord(name: "x", executable: "/does-not-exist")
        )
        #expect(SessionWindowModel.NavigationTarget.live(starting).windowTarget == nil)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct DiscardWorktreeWindowTests {
    @Test(arguments: [false, true])
    func discardShowsTheSessionReadOnlyInEveryWindow(dismissedBeforeAction: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-discard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(filePath: "/bin/sh")
        git.arguments = [
            "-c",
            "git init -q && git -c user.name=T -c user.email=t@example.com -c commit.gpgsign=false "
                + "commit -q --allow-empty -m Initial",
        ]
        git.currentDirectoryURL = repo
        // Waiting synchronously would block the main actor shared by the other suites.
        let status = try await withCheckedThrowingContinuation { continuation in
            git.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try git.run() } catch { continuation.resume(throwing: error) }
        }
        #expect(status == 0)
        let sessions = SessionManager(
            library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")),
            worktreesRoot: directory.appending(path: "trees")
        )
        sessions.environment = { (ProcessInfo.processInfo.environment, nil) }
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        let model = SessionWindowModel(sessions: sessions)
        let other = SessionWindowModel(sessions: sessions)
        model.start(directory: repo, executable: binary.path, arguments: ["--reopen"])
        let owner = try #require(model.owner)
        #expect(!model.canDiscard)
        await owner.startup?.value
        await model.refresh()
        let record = try #require(owner.controller?.session)
        #expect(model.canDiscard && !model.canContinue)
        await model.requestDiscard(record)
        let pending = try #require(model.pendingDiscard)
        #expect(pending.title == "Discard the worktree of “\(record.title ?? "New Session")”?")
        #expect(
            pending.message
                == "0 uncommitted files and 0 commits on agenthesia/\(record.id.uuidString.lowercased()) will be deleted. This cannot be undone."
        )
        if dismissedBeforeAction {
            // SwiftUI dismisses the alert before its button's asynchronous task gets to run.
            model.isConfirmingDiscard = false
            #expect(model.pendingDiscard == nil)
            #expect(FileManager.default.fileExists(atPath: record.workingDirectory))
            #expect(owner.isLive)
        }
        await model.confirmDiscard(pending)
        #expect(model.pendingDiscard == nil && model.alertMessage == nil)
        #expect(sessions.owners.isEmpty)
        #expect(model.restored?.transcript.worktreeOutcome == .discarded)
        #expect(model.outcomes == [record.id: .discarded])
        #expect(!model.canDiscard && !model.canContinue && model.filesSession == nil)
        #expect(RootView.statusText(try #require(model.restored)) == "The worktree was discarded. Read-only.")
        #expect(!FileManager.default.fileExists(atPath: record.workingDirectory))
        // Another window learns the outcome with history, before loading the transcript.
        await other.refresh()
        #expect(!other.canDiscard(record))
        await other.showHistory(record)
        #expect(!other.canContinue && !other.canDiscard)
        // A retry from a stale menu reports the recorded outcome instead of asking again.
        other.outcomes = [:]
        other.restored = nil
        await other.requestDiscard(record)
        #expect(other.pendingDiscard == nil)
        #expect(other.alertMessage == SessionManager.DiscardError.alreadyRemoved.localizedDescription)
    }

    @Test func confirmationTextCountsWhatIsLost() {
        let record = SessionRecord(projectID: UUID(), agentInstallID: UUID(), title: "Fix", workingDirectory: "/tmp")
        let one = SessionWindowModel.PendingDiscard(
            session: record,
            summary: .init(uncommittedFiles: 1, commits: 1, branch: "agenthesia/x")
        )
        #expect(
            one.message == "1 uncommitted file and 1 commit on agenthesia/x will be deleted. This cannot be undone."
        )
        let unknown = SessionWindowModel.PendingDiscard(session: record, summary: nil)
        #expect(unknown.title == "Discard the worktree of “Fix”?")
        #expect(unknown.message.hasSuffix("This cannot be undone."))
    }

    @Test func sessionsWithoutAnAgenthesiaWorktreeCannotBeDiscarded() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-plain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        let store = try await sessions.library.store()
        let project = ProjectRecord(name: "Plain", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Test", executable: "unused")
        let record = SessionRecord(
            projectID: project.id,
            agentInstallID: agent.id,
            agentSessionID: "saved",
            workingDirectory: directory.path
        )
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        try await store.createSession(record)
        let model = SessionWindowModel(sessions: sessions)
        await model.refresh()
        await model.showHistory(record)
        #expect(model.canContinue && !model.canDiscard && !model.canDiscard(record))
        await model.requestDiscard(record)
        #expect(model.pendingDiscard == nil)
    }
}
