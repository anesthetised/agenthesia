import Foundation
import Testing

@testable import Workspace

/// Worktrees start from the fetched upstream (ADR-0047), with a local bare repository as the remote.
@Suite(.timeLimit(.minutes(1))) struct WorktreeUpstreamTests {
    typealias Fixture = WorktreeRemovalTests.Fixture

    /// `repo` tracks `origin/main` in a bare `remote.git`; `other` is a second clone that pushes to it.
    func fixture() async throws -> (fixture: Fixture, other: URL) {
        let fixture = try await Fixture()
        let remote = fixture.directory.appending(path: "remote.git")
        try await SessionWorkspace.git(["init", "-q", "--bare", "-b", "main", remote.path], in: fixture.directory)
        try await SessionWorkspace.git(["remote", "add", "origin", remote.path], in: fixture.repo)
        try await SessionWorkspace.git(["push", "-q", "-u", "origin", "main"], in: fixture.repo)
        let other = fixture.directory.appending(path: "other")
        try await SessionWorkspace.git(["clone", "-q", remote.path, other.path], in: fixture.directory)
        return (fixture, other)
    }

    /// Pushes a commit adding `name` from `other`, so `repo` and its `origin/main` fall behind; returns the commit.
    func pushUpstream(_ name: String, from other: URL, fixture: Fixture) async throws -> String {
        try name.write(to: other.appending(path: name), atomically: true, encoding: .utf8)
        try await SessionWorkspace.git(["add", name], in: other)
        try await fixture.commit(name, in: other)
        try await SessionWorkspace.git(["push", "-q", "origin", "main"], in: other)
        return try await SessionWorkspace.git(["rev-parse", "HEAD"], in: other)
    }

    func head(_ directory: URL) async throws -> String {
        try await SessionWorkspace.git(["rev-parse", "HEAD"], in: directory)
    }

    @Test func startsFromTheFetchedUpstreamAndMergesOnlyOnceTheLocalBranchContainsIt() async throws {
        let (fixture, other) = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let local = try await head(fixture.repo)
        let upstream = try await pushUpstream("upstream", from: other, fixture: fixture)
        #expect(await SessionWorkspace.worktreeBase(of: fixture.repo) == "origin/main")

        let (workspace, worktree) = try await fixture.prepare()
        #expect(workspace.baseRevision == upstream)
        #expect(workspace.baseBranch == "main")
        #expect(workspace.fallbackUpstream == nil)
        #expect(FileManager.default.fileExists(atPath: workspace.workingDirectory.appending(path: "upstream").path))
        // The app fetches but never pulls: the local branch stays where the user left it.
        #expect(try await head(fixture.repo) == local)

        try "session".write(
            to: workspace.workingDirectory.appending(path: "session"),
            atomically: true,
            encoding: .utf8
        )
        #expect(
            try await SessionWorkspace.mergeCheck(of: worktree, into: "main", baseRevision: upstream)
                == .blocked(.baseBranchBehind(base: "main", upstream: "origin/main"))
        )
        await #expect(
            throws: SessionWorkspace.MergeFailure.blocked(.baseBranchBehind(base: "main", upstream: "origin/main"))
        ) {
            try await SessionWorkspace.merge(worktree, into: "main", baseRevision: upstream, message: "Session")
        }
        #expect(try await head(fixture.repo) == local)
        // Review shows the session's own work, not the upstream's commit.
        var review = try await SessionWorkspace.review(
            in: workspace.workingDirectory,
            baseBranch: "main",
            baseRevision: upstream
        )
        #expect(review.baseRevision == upstream)
        #expect(review.changes.map(\.path) == ["session"])

        try await SessionWorkspace.git(["merge", "-q", "--ff-only", "origin/main"], in: fixture.repo)
        #expect(
            try await SessionWorkspace.mergeCheck(of: worktree, into: "main", baseRevision: upstream)
                == .ready(files: 1, commits: 0)
        )
        review = try await SessionWorkspace.review(
            in: workspace.workingDirectory,
            baseBranch: "main",
            baseRevision: upstream
        )
        #expect(review.changes.map(\.path) == ["session"])
    }

    @Test func withoutAnUpstreamTheWorktreeStartsFromHEAD() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(await SessionWorkspace.worktreeBase(of: fixture.repo) == "main")
        let (workspace, _) = try await fixture.prepare()
        #expect(workspace.baseRevision == (try await head(fixture.repo)))
        #expect(workspace.fallbackUpstream == nil)
    }

    @Test func aFailedFetchStartsFromHEADAndRecordsTheUpstream() async throws {
        let (fixture, other) = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await pushUpstream("upstream", from: other, fixture: fixture)
        let missing = fixture.directory.appending(path: "missing.git")
        try await SessionWorkspace.git(["remote", "set-url", "origin", missing.path], in: fixture.repo)
        let (workspace, worktree) = try await fixture.prepare()
        #expect(workspace.baseRevision == (try await head(fixture.repo)))
        #expect(workspace.fallbackUpstream == "origin/main")
        try "session".write(
            to: workspace.workingDirectory.appending(path: "session"),
            atomically: true,
            encoding: .utf8
        )
        #expect(
            try await SessionWorkspace.mergeCheck(of: worktree, into: "main", baseRevision: workspace.baseRevision)
                == .ready(files: 1, commits: 0)
        )
    }

    @Test func aFetchOverTheLimitStartsFromHEAD() async throws {
        let (fixture, other) = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await pushUpstream("upstream", from: other, fixture: fixture)
        let workspace = try await SessionWorkspace.prepare(
            directory: fixture.repo,
            id: UUID(),
            worktreesRoot: fixture.trees,
            fetchTimeout: .zero
        )
        #expect(workspace.baseRevision == (try await head(fixture.repo)))
        #expect(workspace.fallbackUpstream == "origin/main")
    }

    @Test func theBehindExplanationNamesBothBranches() {
        #expect(
            SessionWorkspace.MergeBlocker.baseBranchBehind(base: "main", upstream: "origin/main").explanation
                == "The session started from a newer origin/main than “main” contains. Pull origin/main into “main” "
                + "first, then merge."
        )
        #expect(
            SessionWorkspace.MergeBlocker.baseBranchBehind(base: "main", upstream: nil).explanation.contains("“main”")
        )
    }
}
