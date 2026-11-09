import Foundation
import Synchronization
import Testing

@testable import Workspace

/// Sessions in the project folder of a Git repository (ADR-0043): no worktree, no branch, no fetch.
@Suite(.timeLimit(.minutes(1))) struct ProjectFolderWorkspaceTests {
    typealias Fixture = WorktreeRemovalTests.Fixture

    func prepare(_ directory: URL, id: UUID = UUID(), fixture: Fixture) async throws -> SessionWorkspace {
        try await SessionWorkspace.prepare(
            directory: directory,
            id: id,
            topic: "Explain the module",
            inProjectFolder: true,
            worktreesRoot: fixture.trees
        )
    }

    func head(_ directory: URL) async throws -> String {
        try await SessionWorkspace.git(["rev-parse", "HEAD"], in: directory)
    }

    @Test func worksInTheCheckoutWithItsHEADAsTheBase() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let id = UUID()
        let workspace = try await prepare(fixture.repo, id: id, fixture: fixture)
        let repo = fixture.repo.resolvingSymlinksInPath().standardizedFileURL
        #expect(workspace.projectDirectory.path == repo.path)
        #expect(workspace.workingDirectory.path == repo.path)
        #expect(workspace.baseRevision == (try await head(fixture.repo)))
        #expect(workspace.baseBranch == "main")
        #expect(workspace.branch == nil)
        #expect(workspace.fallbackUpstream == nil)
        // Nothing of Agenthesia's: no worktree, no branch, no folder under the worktrees root.
        #expect(!FileManager.default.fileExists(atPath: fixture.trees.path))
        #expect(try await fixture.branches() == ["main"])
        let worktrees = try await SessionWorkspace.git(["worktree", "list", "--porcelain"], in: fixture.repo)
        #expect(worktrees.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count == 1)
        // The removal check's location test never matches, with or without a stored branch.
        for branch in [nil, SessionWorkspace.legacyBranchName(for: id)] {
            #expect(
                SessionWorkspace.Worktree(
                    projectDirectory: workspace.projectDirectory,
                    workingDirectory: workspace.workingDirectory,
                    sessionID: id,
                    branch: branch,
                    worktreesRoot: fixture.trees
                ) == nil
            )
        }
    }

    @Test func keepsTheSelectedSubdirectoryEvenWhenUntracked() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let subdirectory = fixture.repo.appending(path: "packages/foo")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let workspace = try await prepare(subdirectory, fixture: fixture)
        #expect(workspace.projectDirectory.path == fixture.repo.resolvingSymlinksInPath().path)
        #expect(workspace.workingDirectory.path == subdirectory.resolvingSymlinksInPath().path)
        #expect(workspace.baseRevision == (try await head(fixture.repo)))
    }

    @Test func aDetachedHEADHasNoBaseBranch() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await SessionWorkspace.git(["checkout", "-q", "--detach"], in: fixture.repo)
        let workspace = try await prepare(fixture.repo, fixture: fixture)
        #expect(workspace.baseRevision == (try await head(fixture.repo)))
        #expect(workspace.baseBranch == nil)
        #expect(workspace.branch == nil)
    }

    @Test func aDirtyCheckoutStaysAsItIsAndChangesCountFromTheStart() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try "dirty".write(to: fixture.repo.appending(path: "file"), atomically: true, encoding: .utf8)
        let workspace = try await prepare(fixture.repo, fixture: fixture)
        #expect(try String(contentsOf: fixture.repo.appending(path: "file"), encoding: .utf8) == "dirty")
        // A commit made in the checkout after the start is among the session's changes, and so is the dirty file.
        try "new".write(to: fixture.repo.appending(path: "added"), atomically: true, encoding: .utf8)
        try await SessionWorkspace.git(["add", "added"], in: fixture.repo)
        try await fixture.commit("Added", in: fixture.repo)
        let base = try #require(workspace.baseRevision)
        let paths = try await SessionWorkspace.changedPaths(in: workspace.workingDirectory, baseRevision: base)
        #expect(paths == ["added", "file"])
        let review = try await SessionWorkspace.review(
            in: workspace.workingDirectory,
            baseBranch: nil,
            baseRevision: base
        )
        #expect(review.baseRevision == base)
        #expect(review.changes.map(\.path) == ["added", "file"])
    }

    @Test func neverFetchesTheUpstream() async throws {
        let (fixture, other) = try await WorktreeUpstreamTests().fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let local = try await head(fixture.repo)
        _ = try await WorktreeUpstreamTests().pushUpstream("upstream", from: other, fixture: fixture)
        let fetched = Mutex<[String]>([])
        let workspace = try await SessionWorkspace.prepare(
            directory: fixture.repo,
            id: UUID(),
            inProjectFolder: true,
            worktreesRoot: fixture.trees,
            onFetch: { upstream in fetched.withLock { $0.append(upstream) } }
        )
        #expect(workspace.baseRevision == local)
        #expect(workspace.fallbackUpstream == nil)
        #expect(fetched.withLock { $0 }.isEmpty)
        #expect(try await SessionWorkspace.git(["rev-parse", "origin/main"], in: fixture.repo) == local)
    }

    @Test func theBareAndBrokenRepositoryChecksStay() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bare = fixture.directory.appending(path: "bare.git")
        try await SessionWorkspace.git(["init", "-q", "--bare", bare.path], in: fixture.directory)
        let bareError = await #expect(throws: (any Error).self) { try await prepare(bare, fixture: fixture) }
        #expect(bareError?.localizedDescription.contains("bare repository") == true)
        let broken = fixture.directory.appending(path: "broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: broken.appending(path: ".git"),
            withDestinationURL: broken.appending(path: "missing")
        )
        let brokenError = await #expect(throws: (any Error).self) { try await prepare(broken, fixture: fixture) }
        #expect(brokenError?.localizedDescription.contains(".git entry") == true)
        // A repository without commits has no HEAD to start from.
        let empty = fixture.directory.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try await SessionWorkspace.git(["init", "-q"], in: empty)
        await #expect(throws: (any Error).self) { try await prepare(empty, fixture: fixture) }
    }
}
