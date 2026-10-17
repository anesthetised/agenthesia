import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionActivityTests {
    private typealias Activity = LiveSession.Activity

    private func derive(
        starting: Bool = false,
        failed: Bool = false,
        status: SessionController.Status? = .idle,
        needsInput: Bool = false,
        unseen: Bool = false
    ) -> Activity {
        Activity.derive(starting: starting, failed: failed, status: status, needsInput: needsInput, unseen: unseen)
    }

    @Test func statusPriorityIsNeedsInputFailedWorkingDoneIdle() {
        #expect(derive(failed: true, status: .running, needsInput: true, unseen: true) == .needsInput)
        #expect(derive(failed: true, status: .closed, unseen: true) == .failed)
        #expect(derive(status: .failed, unseen: true) == .failed)
        #expect(derive(starting: true, status: nil, unseen: true) == .working)
        for status in [SessionController.Status.starting, .running, .stopping] {
            #expect(derive(status: status, unseen: true) == .working)
        }
        #expect(derive(unseen: true) == .done)
        #expect(derive() == .idle)
        #expect(derive(status: .closed) == .idle)
    }

    private func fixture() throws -> (URL, SessionManager, AgentInstallRecord) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "session-activity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SessionManager(
            library: SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite"))
        )
        manager.environment = { (ProcessInfo.processInfo.environment, nil) }
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        return (directory, manager, AgentInstallRecord(name: "Mock", executable: binary.path))
    }

    @Test func aFinishedTurnIsDoneUntilSeenAndStopDoesNotCount() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = manager.start(directory: directory, agent: agent)
        #expect(owner.activity == .working)
        await owner.startup?.value
        #expect(owner.activity == .idle && !owner.hasUnseenResult)
        await owner.send("hello")
        #expect(owner.activity == .done)
        owner.markSeen()
        #expect(owner.activity == .idle)
        let controller = try #require(owner.controller)
        let turn = Task { await owner.send("slow") }
        while controller.status == .idle { await Task.yield() }
        #expect(owner.activity == .working)
        await owner.stop()
        await turn.value
        #expect(owner.activity == .idle)
        await owner.send("again")
        #expect(owner.activity == .done)
        await manager.closeAll()
    }

    @Test func failedConnectionsAndStartupsShowAsFailed() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        await owner.send("fail")
        while owner.controller?.status != .closed { await Task.yield() }
        #expect(owner.activity == .failed)
        await manager.closeAll()
        let missing = manager.start(directory: directory, agent: AgentInstallRecord(name: "x", executable: "/nope"))
        await missing.startup?.value
        #expect(missing.activity == .failed)
        await manager.closeAll()
    }

    @Test func sidebarGroupsByProjectNewestFirstWithLiveRowsAhead() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = ProjectRecord(name: "Old", rootPath: "/old")
        let recent = ProjectRecord(name: "Recent", rootPath: "/recent")
        let empty = ProjectRecord(name: "Empty", rootPath: "/empty")
        func record(_ project: ProjectRecord, age: TimeInterval) -> SessionRecord {
            SessionRecord(
                projectID: project.id,
                agentInstallID: UUID(),
                workingDirectory: project.rootPath,
                createdAt: Date(timeIntervalSinceNow: -age)
            )
        }
        let (oldest, older, newer) = (record(old, age: 300), record(recent, age: 200), record(recent, age: 100))
        let owner = manager.start(directory: directory, agent: agent)
        let pending = SessionSidebar(projects: [old, recent, empty], history: [oldest, older, newer], owners: [owner])
        #expect(pending.starting.count == 1 && pending.starting[0] === owner)
        #expect(pending.groups.map(\.project.name) == ["Recent", "Old"])
        await owner.startup?.value
        let live = try #require(owner.controller?.session)
        let project = try #require(try await manager.library.projects().first)
        let sidebar = SessionSidebar(
            projects: [old, recent, empty, project],
            history: [oldest, older, newer, live],
            owners: [owner]
        )
        #expect(sidebar.starting.isEmpty)
        #expect(sidebar.groups.map(\.project.name) == [project.name, "Recent", "Old"])
        let rows = sidebar.groups[0].rows
        #expect(rows.map(\.id) == [live.id])
        guard case .live(let shown, _) = rows[0] else {
            Issue.record("Expected a live row")
            return
        }
        #expect(shown === owner)
        let recentRows = sidebar.groups[1].rows
        #expect(recentRows.map(\.id) == [newer.id, older.id])
        await manager.closeAll()
    }

    @Test func liveRowsKeepStartOrderBeforeSavedOnes() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = manager.start(directory: directory, agent: agent)
        let second = manager.start(directory: directory, agent: agent)
        await first.startup?.value
        await second.startup?.value
        let (a, b) = try (#require(first.controller?.session), #require(second.controller?.session))
        let projects = try await manager.library.projects()
        let saved = SessionRecord(
            projectID: a.projectID,
            agentInstallID: a.agentInstallID,
            workingDirectory: a.workingDirectory,
            createdAt: .now.addingTimeInterval(60)
        )
        let sidebar = SessionSidebar(projects: projects, history: [a, b, saved], owners: [first, second])
        #expect(sidebar.groups.count == 1)
        #expect(sidebar.groups[0].rows.map(\.id) == [a.id, b.id, saved.id])
        await manager.closeAll()
    }
}
