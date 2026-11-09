import Foundation
import Synchronization
import Testing
import Workspace

@testable import AgenthesiaCore
@testable import Persistence

/// Deleting a saved session (ADR-0044), with real repositories: the worktree goes first, then the history.
extension WorktreeDiscardTests {
    func isGone(_ session: SessionRecord, in manager: SessionManager) async throws -> Bool {
        let store = try await manager.library.store()
        guard try await store.session(id: session.id) == nil else { return false }
        return try await store.events(in: session.id).isEmpty
    }

    @Test func deletingASavedSessionRemovesItsWorktreeBranchAndHistory() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await start(fixture)
        let (other, otherSession) = try await start(fixture)
        await owner.send("hello")
        let working = URL(filePath: session.workingDirectory)
        try "work".write(to: working.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: working)
        try await git(["commit", "-qm", "Work"], in: working)
        try "dirty".write(to: working.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: SessionManager.DeleteError.live) { try await manager.delete(session) }
        #expect(FileManager.default.fileExists(atPath: session.workingDirectory))
        await manager.end(owner)
        let branch = try #require(session.branch)
        #expect(
            try await manager.deleteSummary(session)
                == .worktree(.init(uncommittedFiles: 1, commits: 1, branch: branch))
        )
        try await manager.delete(session)
        #expect(try await isGone(session, in: manager))
        #expect(!FileManager.default.fileExists(atPath: session.workingDirectory))
        #expect(try await branches(fixture.repo).sorted() == [try #require(otherSession.branch), "main"])
        #expect(manager.deletingIDs.isEmpty)
        // The other session, its project and the base branch are untouched.
        #expect(other.isLive && FileManager.default.fileExists(atPath: otherSession.workingDirectory))
        #expect(try await manager.library.history().map(\.id) == [otherSession.id])
        #expect(try String(contentsOf: fixture.repo.appending(path: "file.txt"), encoding: .utf8) == "initial")
        await manager.closeAll()
    }

    @Test func aFailedRemovalDeletesNothing() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await start(fixture)
        await manager.end(owner)
        let events = try await manager.library.store().events(in: session.id)
        // A locked worktree needs a second --force, so Git refuses to remove it.
        try await git(["worktree", "lock", session.workingDirectory], in: fixture.repo)
        await #expect(throws: (any Error).self) { try await manager.delete(session) }
        #expect(FileManager.default.fileExists(atPath: session.workingDirectory))
        #expect(try await manager.library.store().session(id: session.id) == session)
        #expect(try await manager.library.store().events(in: session.id) == events)
        #expect(manager.deletingIDs.isEmpty)
        try await git(["worktree", "unlock", session.workingDirectory], in: fixture.repo)
        try await manager.delete(session)
        #expect(try await isGone(session, in: manager))
    }

    @Test func aDiscardedOrMergedSessionLosesOnlyItsHistory() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, discarded) = try await start(fixture)
        await manager.end(owner)
        try await manager.discard(discarded)
        #expect(try await manager.deleteSummary(discarded) == .discarded)
        try await manager.delete(discarded)
        #expect(try await isGone(discarded, in: manager))
        let id = UUID()
        let merged = try await savedSession(
            fixture,
            branch: "agenthesia/\(id.uuidString.lowercased())",
            stored: nil,
            id: id
        )
        try await manager.library.record(.merged(commit: "abc", into: "main"), for: merged.id)
        #expect(try await manager.deleteSummary(merged) == .merged)
        // A merge whose removal failed leaves its worktree; deleting removes it too.
        try await manager.delete(merged)
        #expect(try await isGone(merged, in: manager))
        #expect(!FileManager.default.fileExists(atPath: merged.workingDirectory))
    }

    @Test func aSessionWithoutEventsFailedToStartAndOneOutsideAWorktreeKeepsItsFiles() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let library = manager.library
        // A session in the user's own checkout: nothing of it is Agenthesia's to remove.
        let session = SessionRecord(
            projectID: try await library.project(directory: fixture.repo.resolvingSymlinksInPath()).id,
            agentInstallID: try await library.install(fixture.agent).id,
            workingDirectory: fixture.repo.resolvingSymlinksInPath().path
        )
        try await library.store().createSession(session)
        #expect(try await manager.deleteSummary(session) == .failedToStart)
        _ = try await library.store().append([.init(kind: "note", payload: Data("{}".utf8))], to: session.id)
        #expect(try await manager.deleteSummary(session) == .history)
        try await manager.delete(session)
        #expect(try await isGone(session, in: manager))
        #expect(FileManager.default.fileExists(atPath: fixture.repo.appending(path: "file.txt").path))
        #expect(try await branches(fixture.repo) == ["main"])
    }

    @Test func aSessionWithoutAProjectMovesItsFolderToTheTrash() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let scratch = fixture.directory.appending(path: "scratch")
        let manager = SessionManager(
            library: fixture.manager.library,
            worktreesRoot: fixture.trees,
            scratchRoot: scratch
        )
        manager.environment = { (ProcessInfo.processInfo.environment, nil) }
        let trashed = Trashed()
        manager.trash = { url in
            trashed.urls.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }
        let owner = manager.start(directory: nil, agent: fixture.agent, initialPrompt: .init(text: "Plan a trip"))
        await owner.startup?.value
        let session = try #require(owner.controller?.session)
        let folder = URL(filePath: session.workingDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "notes"), withIntermediateDirectories: true)
        try "a".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: folder.appending(path: "notes/b.txt"), atomically: true, encoding: .utf8)
        await manager.end(owner)
        #expect(try await manager.deleteSummary(session) == .folder(name: folder.lastPathComponent, files: 2))
        try await manager.delete(session)
        #expect(try await isGone(session, in: manager))
        #expect(trashed.urls.withLock { $0.map(\.path) } == [folder.path])
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        // A stored path that is not directly in the scratch root is never touched.
        let elsewhere = fixture.directory.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let planted = SessionRecord(
            projectID: session.projectID,
            agentInstallID: session.agentInstallID,
            workingDirectory: elsewhere.path
        )
        try await manager.library.store().createSession(planted)
        #expect(try await manager.deleteSummary(planted) == .failedToStart)
        try await manager.delete(planted)
        #expect(try await isGone(planted, in: manager))
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
        let climbing = SessionRecord(
            projectID: session.projectID,
            agentInstallID: session.agentInstallID,
            workingDirectory: SessionWorkspace.scratchProjectPath(scratch) + "/../elsewhere"
        )
        try await manager.library.store().createSession(climbing)
        try await manager.delete(climbing)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
        #expect(trashed.urls.withLock { $0.count } == 1)
    }
}

private final class Trashed: Sendable {
    let urls = Mutex<[URL]>([])
}
