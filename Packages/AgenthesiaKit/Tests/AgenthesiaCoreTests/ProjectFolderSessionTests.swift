import Foundation
import Testing
import Workspace

@testable import AgenthesiaCore
@testable import Persistence

/// Sessions in the project folder of a Git repository (ADR-0043), with real repositories: nothing of the user's
/// checkout is ever merged, discarded or removed.
extension WorktreeDiscardTests {
    func startInProjectFolder(_ fixture: Fixture, in directory: URL) async throws -> (LiveSession, SessionRecord) {
        let owner = fixture.manager.start(
            directory: directory,
            inProjectFolder: true,
            agent: fixture.agent,
            initialPrompt: .init(text: "Where is the retry logic?")
        )
        await owner.startup?.value
        return (owner, try #require(owner.controller?.session))
    }

    @Test func aProjectFolderSessionIsNeverMergedDiscardedOrRemoved() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        try "dirty".write(to: fixture.repo.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        let head = try await git(["rev-parse", "HEAD"], in: fixture.repo)
        let (owner, session) = try await startInProjectFolder(fixture, in: fixture.repo)
        #expect(owner.startPlace == .projectFolder)
        #expect(owner.initialPrompt == nil)
        let repo = fixture.repo.resolvingSymlinksInPath()
        #expect(session.workingDirectory == repo.path)
        #expect(session.baseRevision == head)
        #expect(session.baseBranch == "main")
        #expect(session.branch == nil)
        #expect(try await manager.library.project(id: session.projectID)?.rootPath == repo.path)
        #expect(manager.worksInProjectFolder(session))
        #expect(!manager.canDiscard(session, project: try await project(of: session, in: manager)))
        await #expect(throws: SessionManager.DiscardError.notRemovable) { try await manager.discardSummary(session) }
        await #expect(throws: SessionManager.DiscardError.notRemovable) { try await manager.discard(session) }
        #expect(owner.isLive)
        await manager.end(owner)
        await #expect(throws: SessionManager.DiscardError.notRemovable) { try await manager.mergeCheck(session) }
        await #expect(throws: SessionManager.DiscardError.notRemovable) {
            try await manager.merge(session, message: "Merge")
        }
        #expect(await manager.pullRequestTarget(session) == nil)
        #expect(await !manager.hasUnpushedWork(session))

        // Deleting it deletes its history only: no legacy branch name is derived, nothing of the checkout goes.
        #expect(try await manager.deleteSummary(session) == .history)
        try await manager.delete(session)
        #expect(try await isGone(session, in: manager))
        #expect(try String(contentsOf: fixture.repo.appending(path: "file.txt"), encoding: .utf8) == "dirty")
        #expect(try await branches(fixture.repo) == ["main"])
        #expect(try await git(["rev-parse", "HEAD"], in: fixture.repo) == head)
        let worktrees = try await git(["worktree", "list", "--porcelain"], in: fixture.repo)
        #expect(worktrees.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.trees.path))
    }

    @Test func aFailedProjectFolderStartLeavesTheCheckoutAlone() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let subdirectory = fixture.repo.appending(path: "packages/foo")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try "untracked".write(to: subdirectory.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        let owner = fixture.manager.start(
            directory: subdirectory,
            inProjectFolder: true,
            agent: AgentInstallRecord(name: "Exits", executable: "/usr/bin/false"),
            initialPrompt: .init(text: "hello")
        )
        await owner.startup?.value
        #expect(owner.errorMessage != nil)
        #expect(owner.workingDirectory?.path == subdirectory.resolvingSymlinksInPath().path)
        #expect(FileManager.default.fileExists(atPath: subdirectory.appending(path: "notes.txt").path))
        #expect(try await branches(fixture.repo) == ["main"])
        #expect(try await fixture.manager.library.history().isEmpty)
        await fixture.manager.closeAll()
    }

    /// The location test only reads a session as in the project folder when it has a base revision: sessions
    /// without a project (ADR-0048) and folders outside Git have none, and worktree sessions live under the root.
    @Test func onlyAGitSessionOutsideTheWorktreesRootIsInTheProjectFolder() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let scratch = fixture.directory.appending(path: "scratch")
        let manager = SessionManager(
            library: fixture.manager.library,
            worktreesRoot: fixture.trees,
            scratchRoot: scratch
        )
        manager.environment = { (ProcessInfo.processInfo.environment, nil) }
        let (worktreeOwner, worktreeSession) = try await start(fixture)
        #expect(!fixture.manager.worksInProjectFolder(worktreeSession))
        let scratchOwner = manager.start(directory: nil, agent: fixture.agent, initialPrompt: .init(text: "Plan"))
        await scratchOwner.startup?.value
        let scratchSession = try #require(scratchOwner.controller?.session)
        #expect(scratchSession.baseRevision == nil)
        #expect(!manager.worksInProjectFolder(scratchSession))
        await #expect(throws: SessionManager.DiscardError.notRemovable) { try await manager.discard(scratchSession) }
        let plain = fixture.directory.appending(path: "plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let (plainOwner, plainSession) = try await start(fixture, in: plain)
        #expect(plainSession.baseRevision == nil)
        #expect(!fixture.manager.worksInProjectFolder(plainSession))
        // A project-folder choice in a folder outside Git is just the folder.
        let (folderOwner, folderSession) = try await startInProjectFolder(fixture, in: plain)
        #expect(folderSession.baseRevision == nil)
        #expect(!fixture.manager.worksInProjectFolder(folderSession))
        #expect(FileManager.default.fileExists(atPath: scratchSession.workingDirectory))
        for owner in [worktreeOwner, plainOwner, folderOwner] { await fixture.manager.end(owner) }
        await manager.end(scratchOwner)
    }
}
