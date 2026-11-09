import Foundation
import Testing
import Workspace

@testable import AgenthesiaCore
@testable import Persistence

/// Open Pull Request… and Push (ADR-0045) with real repositories: a local bare repository as `origin` and a fake
/// `gh` on `PATH`; never this repository's remote or GitHub.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PullRequestTests {
    typealias Fixture = WorktreeDiscardTests.Fixture
    let helpers = WorktreeDiscardTests()

    /// The merge fixture with `main` tracking `origin/main` in a bare `remote.git`, and a fake `gh` that logs its
    /// arguments to `gh.log` and prints a pull request URL, or fails with `createFailure`.
    func fixture(createFailure: String? = nil) async throws -> (Fixture, remote: URL) {
        let fixture = try await WorktreeMergeTests().fixture()
        let remote = fixture.directory.appending(path: "remote.git")
        try await helpers.git(["init", "-q", "--bare", "-b", "main", remote.path], in: fixture.directory)
        try await helpers.git(["remote", "add", "origin", remote.path], in: fixture.repo)
        try await helpers.git(["push", "-q", "-u", "origin", "main"], in: fixture.repo)
        let bin = fixture.directory.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let create =
            createFailure.map { "echo '\($0)' >&2; exit 1" } ?? "echo https://github.com/example/repo/pull/12"
        let gh = bin.appending(path: "gh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" >> '\(fixture.directory.appending(path: "gh.log").path)'
        if [ "$1" = pr ]; then \(create); fi
        """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        fixture.manager.environment = { [environment] in (environment, nil) }
        return (fixture, remote)
    }

    func savedSession(_ fixture: Fixture) async throws -> SessionRecord {
        let id = UUID()
        return try await helpers.savedSession(
            fixture,
            branch: "agenthesia/\(id.uuidString.lowercased())",
            stored: nil,
            id: id
        )
    }

    func write(_ text: String, to path: String, in session: SessionRecord) throws {
        try text.write(
            to: URL(filePath: session.workingDirectory).appending(path: path),
            atomically: true,
            encoding: .utf8
        )
    }

    func ghLog(_ fixture: Fixture) -> String {
        (try? String(contentsOf: fixture.directory.appending(path: "gh.log"), encoding: .utf8)) ?? ""
    }

    @Test func opensThePullRequestRecordsItAndKeepsTheSession() async throws {
        let (fixture, remote) = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let session = try await savedSession(fixture)
        let branch = "agenthesia/\(session.id.uuidString.lowercased())"
        try write("hello", to: "greeting.txt", in: session)
        let target = try #require(await manager.pullRequestTarget(session))
        #expect(target == .init(remote: "origin", base: "main", branch: branch))

        var steps: [SessionManager.PullRequestStep] = []
        let opened = try await manager.openPullRequest(session, to: target, title: "Greet", body: "Says hello") {
            steps.append($0)
        }
        #expect(steps == [.committing, .pushing, .creating])
        #expect(
            opened == PullRequest(url: try #require(URL(string: "https://github.com/example/repo/pull/12")), number: 12)
        )
        #expect(manager.pushingIDs.isEmpty)
        let worktree = URL(filePath: session.workingDirectory)
        #expect(
            try await helpers.git(["rev-parse", branch], in: remote)
                == helpers.git(["rev-parse", "HEAD"], in: worktree)
        )
        #expect(
            try await helpers.git(["log", "-1", "--format=%s", branch], in: remote)
                == "Agenthesia: uncommitted changes before push"
        )
        #expect(
            ghLog(fixture).contains("pr\ncreate\n--base\nmain\n--head\n\(branch)\n--title\nGreet\n--body\nSays hello\n")
        )

        // The event replays; the session did not end, so its worktree and branch remain.
        let events = try await manager.library.store().events(in: session.id)
        #expect(events.map(\.event.kind) == ["session.pullRequestOpened"])
        let restored = try await SessionController.restore(id: session.id, store: manager.library.store())
        #expect(restored.transcript.pullRequest == opened)
        #expect(
            restored.transcript.items.last?.notice == "Opened pull request #12: https://github.com/example/repo/pull/12"
        )
        #expect(try await manager.library.worktreeOutcomes().isEmpty)
        #expect(FileManager.default.fileExists(atPath: session.workingDirectory))
        #expect(try await manager.discardSummary(session).remoteBranch == "origin/\(branch)")

        // Later work is pushed to the same branch, never forced.
        #expect(!(await manager.hasUnpushedWork(session)))
        try write("more", to: "more.txt", in: session)
        #expect(await manager.hasUnpushedWork(session))
        try await manager.push(session)
        #expect(!(await manager.hasUnpushedWork(session)))
        #expect(
            try await helpers.git(["rev-parse", branch], in: remote)
                == helpers.git(["rev-parse", "HEAD"], in: worktree)
        )
    }

    @Test func aFailingGHLeavesTheBranchPushedAndRecordsNothing() async throws {
        let (fixture, remote) = try await fixture(createFailure: "GraphQL: Head sha can not be blank")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let session = try await savedSession(fixture)
        let branch = "agenthesia/\(session.id.uuidString.lowercased())"
        try write("hello", to: "greeting.txt", in: session)
        let target = try #require(await manager.pullRequestTarget(session))
        var failure: SessionManager.PullRequestError?
        do {
            try await manager.openPullRequest(session, to: target, title: "Greet", body: "")
        } catch let error as SessionManager.PullRequestError { failure = error }
        guard case .step(.creating, let output) = failure?.failure else {
            Issue.record("Expected gh to fail, got \(String(describing: failure))")
            return
        }
        #expect(output.contains("Head sha can not be blank"))
        #expect(
            failure?.localizedDescription.hasPrefix("The branch is pushed, but the pull request was not created.")
                == true
        )
        #expect(try await helpers.git(["rev-parse", "--verify", branch], in: remote).count == 40)
        #expect(try await manager.library.store().events(in: session.id).isEmpty)
        #expect(manager.pushingIDs.isEmpty)
    }

    @Test func aRejectedPushStopsBeforeGH() async throws {
        let (fixture, remote) = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let session = try await savedSession(fixture)
        let branch = "agenthesia/\(session.id.uuidString.lowercased())"
        // The remote has another branch of the same name; it is not overwritten.
        let other = fixture.directory.appending(path: "other")
        try await helpers.git(["clone", "-q", remote.path, other.path], in: fixture.directory)
        try await helpers.git(["checkout", "-q", "-b", branch], in: other)
        try "theirs".write(to: other.appending(path: "theirs.txt"), atomically: true, encoding: .utf8)
        try await helpers.git(["add", "."], in: other)
        try await helpers.git(
            ["-c", "user.name=Other", "-c", "user.email=o@example.com", "commit", "-qm", "Theirs"],
            in: other
        )
        try await helpers.git(["push", "-q", "origin", branch], in: other)
        let theirs = try await helpers.git(["rev-parse", "HEAD"], in: other)
        try write("hello", to: "greeting.txt", in: session)
        let target = try #require(await manager.pullRequestTarget(session))
        var failure: SessionManager.PullRequestError?
        do {
            try await manager.openPullRequest(session, to: target, title: "Greet", body: "")
        } catch let error as SessionManager.PullRequestError { failure = error }
        guard case .step(.pushing, let output) = failure?.failure else {
            Issue.record("Expected the push to fail, got \(String(describing: failure))")
            return
        }
        #expect(output.contains("rejected"))
        #expect(try await helpers.git(["rev-parse", branch], in: remote) == theirs)
        #expect(!ghLog(fixture).contains("pr\ncreate"))
        #expect(try await manager.library.store().events(in: session.id).isEmpty)
    }

    @Test func aLiveSessionShowsThePullRequestAndStaysLive() async throws {
        let (fixture, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await helpers.start(fixture)
        try write("hello", to: "greeting.txt", in: session)
        let target = try #require(await manager.pullRequestTarget(session))
        let opened = try await manager.openPullRequest(session, to: target, title: "Greet", body: "")
        #expect(owner.controller?.transcript.pullRequest == opened)
        #expect(owner.isLive && manager.owner(of: session.id) === owner)
        // Another turn still runs, and the pull request survives it.
        await owner.send("again")
        #expect(owner.controller?.transcript.pullRequest == opened)
        await manager.closeAll()
        let restored = try await SessionController.restore(id: session.id, store: manager.library.store())
        #expect(restored.transcript.pullRequest == opened)
    }

    @Test func hiddenWithoutGHOrARemoteUpstream() async throws {
        let fixture = try await WorktreeMergeTests().fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = try await savedSession(fixture)
        // No remote for main.
        #expect(await fixture.manager.pullRequestTarget(session) == nil)
        let remote = fixture.directory.appending(path: "remote.git")
        try await helpers.git(["init", "-q", "--bare", "-b", "main", remote.path], in: fixture.directory)
        try await helpers.git(["remote", "add", "origin", remote.path], in: fixture.repo)
        try await helpers.git(["push", "-q", "-u", "origin", "main"], in: fixture.repo)
        // A remote, but no gh on PATH.
        let empty = fixture.directory.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        fixture.manager.environment = { (["PATH": empty.path], nil) }
        #expect(await fixture.manager.pullRequestTarget(session) == nil)
    }
}
