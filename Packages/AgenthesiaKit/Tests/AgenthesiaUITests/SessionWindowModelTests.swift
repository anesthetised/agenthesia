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
