import Foundation
import Testing

@testable import Workspace

/// Pull requests from a session branch (ADR-0045), with a local bare repository as the remote and a fake `gh` on
/// `PATH`; never this repository's remote or GitHub.
@Suite(.timeLimit(.minutes(1))) struct WorktreePullRequestTests {
    typealias Fixture = WorktreeRemovalTests.Fixture

    /// A `gh` that logs its arguments, one per line, to `gh.log` beside it, answers `auth status` with
    /// `authStatus` and `pr create` with a pull request URL, or fails with `createFailure` on stderr.
    static func fakeGH(in directory: URL, authStatus: Int32 = 0, createFailure: String? = nil) throws -> URL {
        let bin = directory.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = directory.appending(path: "gh.log").path
        let create =
            createFailure.map { "echo '\($0)' >&2; exit 1" } ?? "echo https://github.com/example/repo/pull/12"
        let script = """
            #!/bin/sh
            printf '%s\\n' "$@" >> '\(log)'
            if [ "$1" = auth ]; then exit \(authStatus); fi
            if [ "$1" = pr ]; then \(create); fi
            """
        let gh = bin.appending(path: "gh")
        try script.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        return bin
    }

    /// The test process's environment with `bin` first on `PATH`.
    static func environment(_ bin: URL) -> [String: String] {
        var values = ProcessInfo.processInfo.environment
        values["PATH"] = "\(bin.path):/usr/bin:/bin"
        return values
    }

    /// A session worktree of a repository tracking `origin/main` in a bare `remote.git`, with an identity and no
    /// signing for the intermediate commit.
    func fixture() async throws -> (Fixture, SessionWorkspace.Worktree, remote: URL) {
        let (fixture, _) = try await WorktreeUpstreamTests().fixture()
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.com"), ("commit.gpgSign", "false")] {
            try await SessionWorkspace.git(["config", key, value], in: fixture.repo)
        }
        let (_, worktree) = try await fixture.prepare()
        return (fixture, worktree, fixture.directory.appending(path: "remote.git"))
    }

    @Test func commitsPushesAndCreatesThePullRequest() async throws {
        let (fixture, worktree, remote) = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let environment = Self.environment(try Self.fakeGH(in: fixture.directory))
        #expect(await SessionWorkspace.gitHubCLIIsSignedIn(environment: environment))
        #expect(
            await SessionWorkspace.remoteUpstream(of: "main", in: fixture.repo)
                == .init(remote: "origin", branch: "main", name: "origin/main")
        )
        #expect(await SessionWorkspace.remoteUpstream(of: worktree.branch, in: worktree.directory) == nil)

        try "work".write(to: worktree.directory.appending(path: "work"), atomically: true, encoding: .utf8)
        #expect(await SessionWorkspace.hasUnpushedWork(in: worktree.directory))
        #expect(try await SessionWorkspace.commitUncommittedChanges(in: worktree.directory, environment: environment))
        #expect(
            try await SessionWorkspace.git(["log", "-1", "--format=%s"], in: worktree.directory)
                == SessionWorkspace.uncommittedChangesMessage
        )
        // Nothing left to commit: no empty commit.
        #expect(!(try await SessionWorkspace.commitUncommittedChanges(in: worktree.directory)))
        try await SessionWorkspace.pushBranch(worktree.branch, to: "origin", in: worktree.directory)
        #expect(
            try await SessionWorkspace.git(["rev-parse", worktree.branch], in: remote)
                == SessionWorkspace.git(["rev-parse", "HEAD"], in: worktree.directory)
        )
        #expect(
            await SessionWorkspace.remoteUpstream(of: worktree.branch, in: worktree.directory)?.name
                == "origin/\(worktree.branch)"
        )
        #expect(!(await SessionWorkspace.hasUnpushedWork(in: worktree.directory)))

        let created = try await SessionWorkspace.createPullRequest(
            base: "main",
            head: worktree.branch,
            title: "Add work",
            body: "Line one\nLine two",
            in: worktree.directory,
            environment: environment
        )
        #expect(created.url.absoluteString == "https://github.com/example/repo/pull/12")
        #expect(created.number == 12)
        let log = try String(contentsOf: fixture.directory.appending(path: "gh.log"), encoding: .utf8)
        #expect(
            log
                == "auth\nstatus\npr\ncreate\n--base\nmain\n--head\n\(worktree.branch)\n--title\nAdd work\n--body\n"
                + "Line one\nLine two\n"
        )

        // A commit the agent made later counts as unpushed work too.
        try "more".write(to: worktree.directory.appending(path: "more"), atomically: true, encoding: .utf8)
        try await SessionWorkspace.git(["add", "more"], in: worktree.directory)
        try await fixture.commit("More", in: worktree.directory)
        #expect(await SessionWorkspace.hasUnpushedWork(in: worktree.directory))
    }

    @Test func aFailingGHThrowsItsOutput() async throws {
        let (fixture, worktree, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bin = try Self.fakeGH(in: fixture.directory, createFailure: "GraphQL: No commits between main and it")
        await #expect(throws: (any Error).self) {
            try await SessionWorkspace.createPullRequest(
                base: "main",
                head: worktree.branch,
                title: "Title",
                body: "",
                in: worktree.directory,
                environment: Self.environment(bin)
            )
        }
        do {
            _ = try await SessionWorkspace.createPullRequest(
                base: "main",
                head: worktree.branch,
                title: "Title",
                body: "",
                in: worktree.directory,
                environment: Self.environment(bin)
            )
        } catch {
            #expect(error.localizedDescription.contains("No commits between"))
        }
    }

    @Test func ghIsMissingOrSignedOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(!(await SessionWorkspace.gitHubCLIIsSignedIn(environment: ["PATH": directory.path])))
        let bin = try Self.fakeGH(in: directory, authStatus: 1)
        #expect(!(await SessionWorkspace.gitHubCLIIsSignedIn(environment: Self.environment(bin))))
    }

    @Test func aRejectedPushThrowsGitsOutput() async throws {
        let (fixture, worktree, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // The remote already has a different branch of that name; the push is never forced.
        let other = fixture.directory.appending(path: "other")
        try await SessionWorkspace.git(["checkout", "-q", "-b", worktree.branch], in: other)
        try "theirs".write(to: other.appending(path: "theirs"), atomically: true, encoding: .utf8)
        try await SessionWorkspace.git(["add", "theirs"], in: other)
        try await fixture.commit("Theirs", in: other)
        try await SessionWorkspace.git(["push", "-q", "origin", worktree.branch], in: other)
        try "mine".write(to: worktree.directory.appending(path: "mine"), atomically: true, encoding: .utf8)
        try await SessionWorkspace.commitUncommittedChanges(in: worktree.directory)
        do {
            try await SessionWorkspace.pushBranch(worktree.branch, to: "origin", in: worktree.directory)
            Issue.record("The push was not rejected.")
        } catch {
            #expect(error.localizedDescription.contains("rejected"))
        }
    }

    @Test func readsThePullRequestFromGHsOutput() {
        let created = SessionWorkspace.pullRequest(
            in: "Creating pull request for x into main in example/repo\n\nhttps://github.com/example/repo/pull/7\n"
        )
        #expect(created?.number == 7)
        #expect(SessionWorkspace.pullRequest(in: "https://github.com/example/repo/pull/new/x") == nil)
        #expect(SessionWorkspace.pullRequest(in: "") == nil)
    }
}
