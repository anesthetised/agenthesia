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

    @Test func sidebarFollowsTheManagerAndRefreshLoadsProjects() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-sidebar-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = manager(directory)
        let model = SessionWindowModel(sessions: sessions)
        let agent = try mock()
        model.start(directory: directory, executable: agent.executable, arguments: [])
        let owner = try #require(model.owner)
        #expect(model.sidebar.starting.count == 1)
        await owner.startup?.value
        await model.refresh()
        #expect(model.projects.count == 1)
        #expect(model.sidebar.starting.isEmpty)
        #expect(model.sidebar.groups.map(\.rows.count) == [1])
        await sessions.end(owner)
        await model.refresh()
        guard case .saved(let record) = model.sidebar.groups.first?.rows.first else {
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
        try await controller.stop()
        try await controller.submit([.init(text: "retained")])
        if failed {
            await owner.send("fail")
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
        for agent in [
            AgentInstallRecord(name: "Missing", executable: "/does-not-exist"), try mock(arguments: ["--auth"]),
        ] {
            model.start(directory: directory, executable: agent.executable, arguments: agent.arguments)
            let owner = try #require(model.owner)
            await owner.startup?.value
            await model.refresh()
            #expect(owner.errorMessage != nil)
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
        model.close()
        #expect(model.navigationTarget() == nil)
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
        try await controller.stop()
        try await controller.submit([.init(text: "queued")])
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
