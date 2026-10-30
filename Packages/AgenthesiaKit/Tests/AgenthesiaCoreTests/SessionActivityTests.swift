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
        await owner.send("exit")
        while owner.controller?.status != .closed { await Task.yield() }
        #expect(owner.activity == .failed)
        await manager.closeAll()
        let missing = manager.start(directory: directory, agent: AgentInstallRecord(name: "x", executable: "/nope"))
        await missing.startup?.value
        #expect(missing.activity == .failed)
        await manager.closeAll()
    }

    @Test func sidebarSectionsFollowActivityAndKeepStartOrder() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let starting = manager.start(directory: directory, agent: agent)
        // A starting owner has no project and no session identity yet, and counts as working.
        let early = SessionSidebar(projects: [], history: [], owners: [starting])
        #expect(early.sections.map(\.kind) == [.working])
        #expect(early.rows.first?.project == nil && early.rows.first?.id == AnyHashable(starting.id))
        await starting.startup?.value
        let finished = manager.start(directory: directory, agent: agent)
        let failed = manager.start(directory: directory, agent: agent)
        let idle = manager.start(directory: directory, agent: agent)
        for owner in [finished, failed, idle] { await owner.startup?.value }
        await finished.send("hello")
        await failed.send("exit")
        while failed.controller?.status != .closed { await Task.yield() }
        #expect(
            [starting.activity, finished.activity, failed.activity, idle.activity] == [.idle, .done, .failed, .idle]
        )

        let project = try #require(try await manager.library.projects().first)
        let other = ProjectRecord(name: "Other", rootPath: "/other")
        func saved(_ project: ProjectRecord, age: TimeInterval) -> SessionRecord {
            SessionRecord(
                projectID: project.id,
                agentInstallID: UUID(),
                workingDirectory: project.rootPath,
                createdAt: Date(timeIntervalSinceNow: -age)
            )
        }
        let (oldest, middle, newest) = (saved(project, age: 300), saved(other, age: 200), saved(project, age: 100))
        let unknown = saved(ProjectRecord(name: "Gone", rootPath: "/gone"), age: 400)
        let live = try [starting, finished, failed, idle].map { try #require($0.sessionID) }
        let liveRecords = try [starting, finished, failed, idle].map { try #require($0.controller?.session) }
        let sidebar = SessionSidebar(
            projects: [project, other],
            history: [oldest, middle, newest, unknown] + liveRecords,
            owners: [starting, finished, failed, idle]
        )

        #expect(sidebar.sections.map(\.kind) == [.needsYou, .working, .settled])
        #expect(sidebar.sections[0].rows.map(\.id) == [AnyHashable(live[1]), AnyHashable(live[2])])
        #expect(sidebar.sections[1].rows.map(\.id) == [AnyHashable(live[0]), AnyHashable(live[3])])
        // Saved sessions that are live are not repeated; the rest are newest first.
        #expect(sidebar.sections[2].rows.map(\.id) == [newest, middle, oldest, unknown].map { AnyHashable($0.id) })
        #expect(sidebar.rows.count == 8)
        #expect(sidebar.sections[0].rows.allSatisfy { $0.project == project })
        #expect(sidebar.sections[2].rows.map(\.project?.name) == [project.name, "Other", project.name, nil])
        guard case .live(let owner) = sidebar.sections[0].rows[0].source,
            case .saved(let record) = sidebar.rows[4].source
        else {
            Issue.record("Expected live rows first and saved rows last")
            return
        }
        #expect(owner === finished && record.id == newest.id)
        await manager.closeAll()
    }

    @Test func emptySectionsAreOmitted() async throws {
        let none = SessionSidebar(projects: [], history: [], owners: [])
        #expect(none.sections.isEmpty && none.rows.isEmpty)
        let record = SessionRecord(projectID: UUID(), agentInstallID: UUID(), workingDirectory: "/x")
        #expect(SessionSidebar(projects: [], history: [record], owners: []).sections.map(\.kind) == [.settled])
    }

    @Test func queryFiltersRowsByTitleAndProject() {
        let cafe = ProjectRecord(name: "Café", rootPath: "/cafe")
        let other = ProjectRecord(name: "Other", rootPath: "/other")
        func saved(_ project: ProjectRecord, title: String?) -> SessionRecord {
            SessionRecord(
                projectID: project.id,
                agentInstallID: UUID(),
                title: title,
                workingDirectory: project.rootPath
            )
        }
        let (fix, plain, untitled) = (
            saved(other, title: "Fix the Login"), saved(cafe, title: "Docs"), saved(other, title: nil)
        )
        func titles(_ query: String) -> [String] {
            SessionSidebar(projects: [cafe, other], history: [fix, plain, untitled], owners: [], query: query)
                .rows.map(\.title).sorted()
        }
        #expect(titles("") == ["Docs", "Fix the Login", "New Session"])
        #expect(titles("  ") == titles(""))
        // Case and diacritics do not matter, and the project name counts.
        #expect(titles("LOGIN") == ["Fix the Login"])
        #expect(titles("cafe") == ["Docs"])
        #expect(titles("other") == ["Fix the Login", "New Session"])
        #expect(titles(" login ") == ["Fix the Login"])
        // An untitled session is found by the title it shows.
        #expect(titles("new sess") == ["New Session"])
        #expect(titles("nothing").isEmpty)
    }

    @Test func queryHidesEmptySectionsAndKeepsOrder() async throws {
        let project = ProjectRecord(name: "Project", rootPath: "/p")
        func saved(_ title: String, age: TimeInterval) -> SessionRecord {
            SessionRecord(
                projectID: project.id,
                agentInstallID: UUID(),
                title: title,
                workingDirectory: project.rootPath,
                createdAt: Date(timeIntervalSinceNow: -age)
            )
        }
        let (older, newer) = (saved("Alpha one", age: 200), saved("Alpha two", age: 100))
        let history = [older, saved("Beta", age: 150), newer]
        let found = SessionSidebar(projects: [project], history: history, owners: [], query: "alpha")
        #expect(found.sections.map(\.kind) == [.settled])
        #expect(found.rows.map(\.id) == [AnyHashable(newer.id), AnyHashable(older.id)])
        #expect(SessionSidebar(projects: [project], history: history, owners: [], query: "zzz").sections.isEmpty)

        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let starting = manager.start(directory: directory, agent: agent)
        // A starting session has no title or project yet; it shows as "New Session".
        let live = SessionSidebar(projects: [project], history: [], owners: [starting], query: "new")
        #expect(live.sections.map(\.kind) == [.working])
        #expect(SessionSidebar(projects: [], history: [], owners: [starting], query: "beta").rows.isEmpty)
        await manager.closeAll()
    }
}
