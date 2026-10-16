import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite struct SessionWindowModelTests {
    @Test func savedHistoryCanBeSelectedAndClosingPreventsNewLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
        let store = try await library.store()
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
        let model = SessionWindowModel(library: library)
        await model.refresh()
        #expect(model.history == [record])
        await model.showHistory(record)
        #expect(model.displayed?.status == .readOnly)
        #expect(!model.isLoadingHistory)
        #expect(model.canContinue)
        // Live in another window: Continue is unavailable until the selection is refreshed.
        #expect(await library.claim(record.id))
        await model.showHistory(record)
        #expect(model.restoredIsLive && !model.canContinue)
        await model.continueRestored()
        #expect(model.owner == nil)
        await library.release(record.id)
        await model.showHistory(record)
        // The configured agent does not exist; the failure is the owner's, history stays listed.
        await model.continueRestored()
        #expect(model.restored == nil)
        #expect(model.filesSession == nil)
        #expect(model.owner?.errorMessage?.contains("unused") == true)
        #expect(model.history == [record])
        await model.showHistory(record)
        model.errorMessage = "Stale"
        model.showLive()
        #expect(model.errorMessage == nil)
        #expect(model.displayed == nil)
        #expect(model.canStart)
        let failed = model.owner
        await model.close()
        #expect(!model.canStart)
        await model.start(directory: directory, executable: "/does-not-exist", arguments: [])
        #expect(model.owner === failed)
    }

    private func mock(arguments: [String] = []) throws -> AgentInstallRecord {
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        return AgentInstallRecord(name: "Mock", executable: binary.path, arguments: arguments)
    }

    @Test(arguments: [false, true])
    func establishedSessionsCanContinueAfterEndOrFailureCleanup(failed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
        let model = SessionWindowModel(library: library)
        let owner = LiveSession(library: library)
        owner.environment = { (ProcessInfo.processInfo.environment, nil) }
        model.owner = owner
        await owner.start(directory: directory, agent: try mock(arguments: ["--reopen"]))
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
        } else {
            await owner.close()
        }
        await model.refresh()
        #expect(controller.status == .closed)
        #expect(model.canContinue)
        #expect(model.savedSessions.contains { $0.id == record.id })
        #expect(model.filesSession?.id == record.id)
        // File browsing follows the session through the startup gap without a controller.
        var finished = false
        var lostFiles = false
        let continuing = Task {
            await model.continueRestored()
            finished = true
        }
        while !finished {
            if model.filesSession?.id != record.id { lostFiles = true }
            await Task.yield()
        }
        await continuing.value
        #expect(!lostFiles)
        let continued = try #require(model.owner?.controller)
        #expect(model.owner !== owner)
        #expect(continued.session.id == record.id)
        #expect(continued.status == .idle)
        #expect(continued.queuePaused)
        #expect(continued.queuedPrompts.map(\.text) == ["retained"])
        await model.close()
    }

    @Test func startupFailuresAndHistoryWithoutRemoteIdentityCannotContinue() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-no-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
        let model = SessionWindowModel(library: library)
        for agent in [
            AgentInstallRecord(name: "Missing", executable: "/does-not-exist"), try mock(arguments: ["--auth"]),
        ] {
            let owner = LiveSession(library: library)
            owner.environment = { (ProcessInfo.processInfo.environment, nil) }
            model.owner = owner
            await owner.start(directory: directory, agent: agent)
            await model.refresh()
            #expect(owner.errorMessage != nil)
            #expect(!model.canContinue)
            #expect(model.savedSessions.isEmpty)
            let original = model.owner
            await model.continueRestored()
            #expect(model.owner === original)
            await owner.close()
        }
        let store = try await library.store()
        let project = ProjectRecord(name: "No remote session", rootPath: directory.appending(path: "other").path)
        let agent = try mock()
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        let record = SessionRecord(projectID: project.id, agentInstallID: agent.id, workingDirectory: directory.path)
        try await store.createSession(record)
        await model.showHistory(record)
        #expect(model.displayed?.status == .readOnly)
        #expect(!model.canContinue)
        await model.close()
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
            library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
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
