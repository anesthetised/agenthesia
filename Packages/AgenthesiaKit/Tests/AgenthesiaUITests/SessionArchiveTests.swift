import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionArchiveTests {
    @MainActor private struct Fixture {
        let directory: URL
        let sessions: SessionManager
        let store: PersistenceStore
        let model: SessionWindowModel
        let project: ProjectRecord
        let agent: AgentInstallRecord

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "archive-\(UUID())")
            sessions = SessionManager(
                library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
            )
            sessions.environment = { (ProcessInfo.processInfo.environment, nil) }
            store = try await sessions.library.store()
            project = ProjectRecord(name: "Project", rootPath: directory.path)
            agent = AgentInstallRecord(name: "Unused", executable: "unused")
            try await store.createProject(project)
            try await store.createAgentInstall(agent)
            model = SessionWindowModel(sessions: sessions)
        }

        func save(_ title: String, at second: Double, archived: Bool = false) async throws -> SessionRecord {
            let record = SessionRecord(
                projectID: project.id,
                agentInstallID: agent.id,
                agentSessionID: "saved",
                title: title,
                workingDirectory: project.rootPath,
                createdAt: Date(timeIntervalSince1970: second)
            )
            try await store.createSession(record)
            if archived { try await store.setArchived(Date(timeIntervalSince1970: 100), of: record.id) }
            return record
        }

        func close() async {
            model.close()
            await sessions.closeAll()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func archivingHidesASavedSessionFromSettledAndUnarchivingBringsItBack() async throws {
        let fixture = try await Fixture()
        let (first, second) = (try await fixture.save("First", at: 1), try await fixture.save("Second", at: 2))
        await fixture.model.refresh()
        #expect(fixture.model.sidebar.rows.count == 2)
        await fixture.model.setArchived(true, first)
        #expect(fixture.model.history.first { $0.id == first.id }?.archivedAt != nil)
        #expect(fixture.model.sidebar.rows.map(\.id) == [AnyHashable(second.id)])
        // The log and the other session are untouched, and the mark survives a reload.
        #expect(try await fixture.store.session(id: second.id)?.archivedAt == nil)
        #expect(try await fixture.store.session(id: first.id)?.archivedAt != nil)
        fixture.model.sidebarQuery = "first"
        #expect(fixture.model.sidebar.rows.map(\.id) == [AnyHashable(first.id)])
        fixture.model.sidebarQuery = ""
        await fixture.model.setArchived(false, first)
        #expect(fixture.model.sidebar.rows.count == 2)
        #expect(try await fixture.store.session(id: first.id)?.archivedAt == nil)
        await fixture.close()
    }

    @Test func archiveAppliesToTheDisplayedSavedSessionOnly() async throws {
        let fixture = try await Fixture()
        let record = try await fixture.save("Saved", at: 1)
        await fixture.model.refresh()
        // The draft shows no session.
        #expect(!fixture.model.canArchive && fixture.model.archiveHelp == nil)
        await fixture.model.showHistory(record)
        #expect(fixture.model.canArchive && fixture.model.archiveHelp == nil)
        #expect(fixture.model.archiveCommandTitle == "Archive Session")
        await fixture.model.toggleArchived()
        #expect(fixture.model.archiveCommandTitle == "Unarchive Session")
        #expect(fixture.model.canArchive)
        await fixture.model.toggleArchived()
        #expect(fixture.model.archiveCommandTitle == "Archive Session")
        #expect(try await fixture.store.session(id: record.id)?.archivedAt == nil)
        await fixture.close()
    }

    @Test func aLiveSessionCannotBeArchivedUntilItEnds() async throws {
        let fixture = try await Fixture()
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        fixture.model.start(directory: fixture.directory, executable: binary.path, arguments: [])
        let owner = try #require(fixture.model.owner)
        await owner.startup?.value
        await fixture.model.refresh()
        let record = try #require(owner.controller?.session)
        #expect(!fixture.model.canArchive && fixture.model.archiveHelp == "End the session first")
        // Nothing is written for a live session, even when asked directly.
        await fixture.model.setArchived(true, record)
        #expect(try await fixture.store.session(id: record.id)?.archivedAt == nil)
        await fixture.model.endSession()
        await fixture.model.showHistory(record)
        #expect(fixture.model.canArchive && fixture.model.archiveHelp == nil)
        await fixture.close()
    }

    @Test func previousAndNextSessionSkipArchivedSessions() async throws {
        let fixture = try await Fixture()
        // Newest first: Third, Second (archived), First.
        let first = try await fixture.save("First", at: 1)
        _ = try await fixture.save("Second", at: 2, archived: true)
        let third = try await fixture.save("Third", at: 3)
        await fixture.model.refresh()
        await fixture.model.navigate()
        #expect(fixture.model.displayed?.session.id == third.id)
        await fixture.model.navigate()
        #expect(fixture.model.displayed?.session.id == first.id)
        await fixture.model.navigate(backward: true)
        #expect(fixture.model.displayed?.session.id == third.id)
        // A search lists the archived session, but navigation still passes it by.
        fixture.model.sidebarQuery = "d"
        #expect(fixture.model.sidebar.rows.count == 2)
        await fixture.model.navigate()
        #expect(fixture.model.displayed?.session.id == third.id)
        fixture.model.sidebarQuery = "second"
        #expect(fixture.model.sidebar.rows.count == 1)
        #expect(fixture.model.navigationTarget() == nil && fixture.model.navigationTarget(backward: true) == nil)
        await fixture.close()
    }

    @Test func continueClearsTheArchivedMark() async throws {
        let fixture = try await Fixture()
        let record = try await fixture.save("Archived", at: 1, archived: true)
        await fixture.model.refresh()
        await fixture.model.showHistory(record)
        #expect(fixture.model.canContinue)
        #expect(fixture.model.history.first?.archivedAt != nil)
        fixture.model.continueRestored()
        let owner = try #require(fixture.model.owner)
        await owner.startup?.value
        // The clearing runs beside the start: wait for the refresh that follows its write.
        while fixture.model.history.first?.archivedAt != nil { await Task.yield() }
        #expect(try await fixture.store.session(id: record.id)?.archivedAt == nil)
        await fixture.close()
    }

    @Test func continuingAnUnarchivedSessionWritesNothing() async throws {
        let fixture = try await Fixture()
        let record = try await fixture.save("Plain", at: 1)
        await fixture.model.refresh()
        await fixture.model.showHistory(record)
        fixture.model.continueRestored()
        await fixture.model.owner?.startup?.value
        #expect(try await fixture.store.session(id: record.id)?.archivedAt == nil)
        await fixture.close()
    }
}
