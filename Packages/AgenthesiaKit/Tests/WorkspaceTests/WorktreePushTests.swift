import Foundation
import Testing

@testable import Workspace

/// Pushing the base branch after a merge (ADR-0045), with a local bare repository as the remote; never this
/// repository's own remote.
@Suite(.timeLimit(.minutes(1))) struct WorktreePushTests {
    typealias Fixture = WorktreeRemovalTests.Fixture

    func head(_ ref: String, in directory: URL) async throws -> String {
        try await SessionWorkspace.git(["rev-parse", ref], in: directory)
    }

    @Test func pushesAMergeToTheUpstreamAndNamesItsRemote() async throws {
        let (fixture, _) = try await WorktreeUpstreamTests().fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let remote = fixture.directory.appending(path: "remote.git")
        #expect(await SessionWorkspace.pushRemote(of: "main", in: fixture.repo) == "origin")
        let (workspace, worktree) = try await fixture.prepare()
        try "session".write(
            to: workspace.workingDirectory.appending(path: "session"),
            atomically: true,
            encoding: .utf8
        )
        let commit = try await SessionWorkspace.merge(
            worktree,
            into: "main",
            baseRevision: workspace.baseRevision,
            message: "Session"
        )
        try await SessionWorkspace.push("main", in: fixture.repo)
        #expect(try await head("main", in: remote) == commit)
        // Pushing again changes nothing and succeeds.
        try await SessionWorkspace.push("main", in: fixture.repo)
    }

    @Test func aRemoteThatMovedRejectsThePushAndTheLocalCommitStays() async throws {
        let (fixture, other) = try await WorktreeUpstreamTests().fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let remote = fixture.directory.appending(path: "remote.git")
        let (workspace, worktree) = try await fixture.prepare()
        try "session".write(
            to: workspace.workingDirectory.appending(path: "session"),
            atomically: true,
            encoding: .utf8
        )
        let commit = try await SessionWorkspace.merge(
            worktree,
            into: "main",
            baseRevision: workspace.baseRevision,
            message: "Session"
        )
        // Someone pushed after the merge check.
        let theirs = try await WorktreeUpstreamTests().pushUpstream("theirs", from: other, fixture: fixture)
        await #expect(throws: (any Error).self) { try await SessionWorkspace.push("main", in: fixture.repo) }
        do {
            try await SessionWorkspace.push("main", in: fixture.repo)
        } catch {
            #expect(error.localizedDescription.contains("rejected"))
        }
        // Nothing was forced, pulled or undone.
        #expect(try await head("main", in: remote) == theirs)
        #expect(try await head("main", in: fixture.repo) == commit)
    }

    @Test func withoutARemoteUpstreamThereIsNothingToPushTo() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(await SessionWorkspace.pushRemote(of: "main", in: fixture.repo) == nil)
        await #expect(throws: (any Error).self) { try await SessionWorkspace.push("main", in: fixture.repo) }
        // A branch that tracks another local branch has no remote either.
        try await SessionWorkspace.git(["branch", "-q", "feature"], in: fixture.repo)
        try await SessionWorkspace.git(["branch", "-q", "--set-upstream-to=main", "feature"], in: fixture.repo)
        #expect(await SessionWorkspace.pushRemote(of: "feature", in: fixture.repo) == nil)
    }

    @Test func aPushThatHangsIsStoppedAfterTheTimeout() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // A transport that never answers, as an unreachable host or a prompt nobody sees would.
        for arguments in [
            ["config", "protocol.ext.allow", "always"],
            ["remote", "add", "slow", "ext::sh -c 'sleep 30'"],
            ["config", "branch.main.remote", "slow"],
            ["config", "branch.main.merge", "refs/heads/main"],
        ] {
            try await SessionWorkspace.git(arguments, in: fixture.repo)
        }
        #expect(await SessionWorkspace.pushRemote(of: "main", in: fixture.repo) == "slow")
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await SessionWorkspace.push("main", in: fixture.repo, timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - start < .seconds(20))
    }
}
