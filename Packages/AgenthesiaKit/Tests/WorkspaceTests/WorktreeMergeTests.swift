import Foundation
import Testing

@testable import Workspace

@Suite(.serialized, .timeLimit(.minutes(1))) struct WorktreeMergeTests {
    typealias Fixture = WorktreeRemovalTests.Fixture

    /// A repository whose merge commits need no global configuration and run only the hooks a test installs.
    func fixture() async throws -> Fixture {
        let fixture = try await Fixture()
        // One write instead of a `git config` process per key: these tests start many Git processes already.
        let config = fixture.repo.appending(path: ".git/config")
        let settings = """

            [user]
            \tname = Test
            \temail = test@example.com
            [commit]
            \tgpgSign = false
            [core]
            \thooksPath = \(fixture.repo.appending(path: ".git/hooks").path)
            """
        let handle = try FileHandle(forWritingTo: config)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(settings.utf8))
        return fixture
    }

    func write(_ text: String, to path: String, in directory: URL) throws {
        let url = directory.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appending(path: path), encoding: .utf8)
    }

    func head(_ directory: URL, _ ref: String = "HEAD") async throws -> String {
        try await SessionWorkspace.git(["rev-parse", ref], in: directory)
    }

    func installHook(_ name: String, _ script: String, in fixture: Fixture) throws {
        let hook = fixture.repo.appending(path: ".git/hooks/\(name)")
        try "#!/bin/sh\n\(script)\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    /// The checkout is exactly at `commit`: nothing staged or modified, and no squash message left behind.
    func expectRestored(_ fixture: Fixture, at commit: String) async throws {
        #expect(try await head(fixture.repo) == commit)
        #expect(
            try await SessionWorkspace.git(["status", "--porcelain", "--untracked-files=no"], in: fixture.repo) == ""
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.repo.appending(path: ".git/SQUASH_MSG").path))
    }

    @Test func squashesCommittedUncommittedAndUntrackedChangesIntoOneCommit() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        let working = workspace.workingDirectory
        let base = try await head(fixture.repo)
        for name in ["a", "b"] {
            try write(name, to: name, in: working)
            try await SessionWorkspace.git(["add", name], in: working)
            try await fixture.commit(name, in: working)
        }
        try write("changed", to: "file", in: working)
        try await SessionWorkspace.git(["rm", "-q", "b"], in: working)
        try write("new", to: "dir/untracked", in: working)
        // `b` was added and removed again: `a`, `file` and the untracked file remain.
        #expect(try await SessionWorkspace.mergeCheck(of: worktree, into: "main") == .ready(files: 3, commits: 2))

        let commit = try await SessionWorkspace.merge(worktree, into: "main", message: "Session work\n\nDetails")
        #expect(try await head(fixture.repo) == commit)
        #expect(try await SessionWorkspace.git(["rev-parse", "\(commit)^"], in: fixture.repo) == base)
        #expect(try await SessionWorkspace.git(["rev-list", "--count", "\(base)..main"], in: fixture.repo) == "1")
        #expect(
            try await SessionWorkspace.git(["log", "-1", "--format=%B", commit], in: fixture.repo)
                == "Session work\n\nDetails"
        )
        // The commit holds exactly the session's tree, uncommitted work included via the intermediate commit.
        #expect(
            try await head(fixture.repo, "\(commit)^{tree}")
                == (try await head(fixture.repo, "\(worktree.branch)^{tree}"))
        )
        #expect(try await SessionWorkspace.git(["status", "--porcelain"], in: worktree.directory) == "")
        #expect(try read("dir/untracked", in: fixture.repo) == "new")
        #expect(try read("file", in: fixture.repo) == "changed")
        #expect(!FileManager.default.fileExists(atPath: fixture.repo.appending(path: "b").path))
        try await expectRestored(fixture, at: commit)
    }

    @Test func mergesOntoABaseThatMovedOnIndependently() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        try write("session", to: "session", in: workspace.workingDirectory)
        try write("base", to: "base", in: fixture.repo)
        try await SessionWorkspace.git(["add", "base"], in: fixture.repo)
        try await fixture.commit("Base", in: fixture.repo)
        let base = try await head(fixture.repo)

        let commit = try await SessionWorkspace.merge(worktree, into: "main", message: "Session")
        #expect(try await SessionWorkspace.git(["rev-parse", "\(commit)^"], in: fixture.repo) == base)
        #expect(try read("base", in: fixture.repo) == "base")
        #expect(try read("session", in: fixture.repo) == "session")
    }

    @Test func aConflictRestoresTheCheckoutAndReportsThePaths() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        try write("session", to: "file", in: workspace.workingDirectory)
        try write("added", to: "added", in: workspace.workingDirectory)
        try write("base", to: "file", in: fixture.repo)
        try await SessionWorkspace.git(["add", "file"], in: fixture.repo)
        try await fixture.commit("Base", in: fixture.repo)
        let base = try await head(fixture.repo)

        await #expect(throws: SessionWorkspace.MergeFailure.conflicts(["file"])) {
            try await SessionWorkspace.merge(worktree, into: "main", message: "Session")
        }
        try await expectRestored(fixture, at: base)
        #expect(try read("file", in: fixture.repo) == "base")
        #expect(!FileManager.default.fileExists(atPath: fixture.repo.appending(path: "added").path))
        // Only the intermediate commit changed the session: its work is committed and kept.
        #expect(try await SessionWorkspace.git(["status", "--porcelain"], in: worktree.directory) == "")
        #expect(try read("file", in: workspace.workingDirectory) == "session")
        #expect(
            try await SessionWorkspace.git(["log", "-1", "--format=%s"], in: worktree.directory)
                == "Uncommitted session changes"
        )
    }

    @Test func aRejectingHookRestoresTheCheckoutWithItsOutput() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        try write("session", to: "added", in: workspace.workingDirectory)
        try installHook("pre-commit", "echo 'lint failed'\nexit 1", in: fixture)
        let base = try await head(fixture.repo)

        do {
            _ = try await SessionWorkspace.merge(worktree, into: "main", message: "Session")
            Issue.record("The merge succeeded despite the hook.")
        } catch SessionWorkspace.MergeFailure.failed(let output) {
            #expect(output.contains("lint failed"))
        }
        try await expectRestored(fixture, at: base)
        #expect(!FileManager.default.fileExists(atPath: fixture.repo.appending(path: "added").path))
    }

    @Test func theFinalCommitRunsHooksWithTheGivenEnvironment() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        try write("session", to: "added", in: workspace.workingDirectory)
        // The hook's tool is found only on the PATH passed in, as with the login shell's.
        let tools = fixture.directory.appending(path: "tools")
        try write("#!/bin/sh\necho hooked >> \"$1\"\n", to: "agh-tool", in: tools)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tools.appending(path: "agh-tool").path
        )
        try installHook("commit-msg", "agh-tool \"$1\"", in: fixture)
        try installHook("pre-commit", "touch \"$(git rev-parse --git-dir)/pre-commit-ran\"", in: fixture)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(tools.path):/usr/bin:/bin"

        let commit = try await SessionWorkspace.merge(
            worktree,
            into: "main",
            message: "Session",
            environment: environment
        )
        #expect(FileManager.default.fileExists(atPath: fixture.repo.appending(path: ".git/pre-commit-ran").path))
        #expect(
            try await SessionWorkspace.git(["log", "-1", "--format=%B", commit], in: fixture.repo) == "Session\nhooked"
        )
    }

    @Test func theIntermediateCommitRunsNoHooks() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        try write("session", to: "added", in: workspace.workingDirectory)
        // `--no-verify` alone would still run these two for the intermediate commit.
        let log = fixture.directory.appending(path: "hooks.log")
        try installHook("prepare-commit-msg", "head -1 \"$1\" >> '\(log.path)'", in: fixture)
        try installHook("post-commit", "echo post >> '\(log.path)'", in: fixture)

        _ = try await SessionWorkspace.merge(worktree, into: "main", message: "Session")
        #expect(try String(contentsOf: log, encoding: .utf8) == "Session\npost\n")
        #expect(
            try await SessionWorkspace.git(["log", "-1", "--format=%s"], in: worktree.directory)
                == "Uncommitted session changes"
        )
    }

    @Test func aFailedRestoreIsReportedAsSuch() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        try write("session", to: "added", in: workspace.workingDirectory)
        // Another Git process holds the checkout's index: the squash fails, and so does the reset after it.
        try write("", to: ".git/index.lock", in: fixture.repo)

        do {
            _ = try await SessionWorkspace.merge(worktree, into: "main", message: "Session")
            Issue.record("The merge ignored the index lock.")
        } catch SessionWorkspace.MergeFailure.notRestored(let output) {
            #expect(output.contains("index.lock"))
        }
    }

    @Test func anUntrackedFileTheMergeWouldOverwriteRestoresTheCheckout() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        try write("session", to: "added", in: workspace.workingDirectory)
        try write("mine", to: "added", in: fixture.repo)
        let base = try await head(fixture.repo)

        do {
            _ = try await SessionWorkspace.merge(worktree, into: "main", message: "Session")
            Issue.record("The merge overwrote an untracked file.")
        } catch SessionWorkspace.MergeFailure.failed(let output) {
            #expect(output.contains("added"))
        }
        try await expectRestored(fixture, at: base)
        #expect(try read("added", in: fixture.repo) == "mine")
    }

    @Test(arguments: [
        "dirty", "other-branch", "detached", "missing-base", "nothing", "no-base", "off-branch", "missing",
        "cherry-pick",
    ])
    func aBlockedMergeWritesNothing(state: String) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        if state != "nothing" { try write("session", to: "added", in: workspace.workingDirectory) }
        var baseBranch: String? = "main"
        let expected: SessionWorkspace.MergeBlocker
        switch state {
        case "dirty":
            try write("edited", to: "file", in: fixture.repo)
            expected = .checkoutHasChanges
        case "other-branch":
            try await SessionWorkspace.git(["checkout", "-qb", "feature/x"], in: fixture.repo)
            expected = .checkoutOnOtherBranch(base: "main", current: "feature/x")
        case "detached":
            try await SessionWorkspace.git(["checkout", "-q", "--detach"], in: fixture.repo)
            expected = .checkoutOnOtherBranch(base: "main", current: nil)
        case "missing-base":
            try await SessionWorkspace.git(["checkout", "-qb", "renamed"], in: fixture.repo)
            try await SessionWorkspace.git(["branch", "-D", "main"], in: fixture.repo)
            expected = .baseBranchMissing("main")
        case "nothing": expected = .nothingToMerge
        case "no-base":
            baseBranch = nil
            expected = .noBaseBranch
        case "off-branch":
            try await SessionWorkspace.git(["checkout", "-qb", "elsewhere"], in: worktree.directory)
            expected = .worktreeUnavailable
        case "cherry-pick":
            // A cherry-pick stopped with nothing staged; `git reset --merge` would abort it.
            let head = try await head(fixture.repo)
            try write(head + "\n", to: ".git/CHERRY_PICK_HEAD", in: fixture.repo)
            expected = .checkoutOperationInProgress
        default:
            try await SessionWorkspace.git(
                ["worktree", "remove", "--force", worktree.directory.path],
                in: fixture.repo
            )
            expected = .worktreeUnavailable
        }
        let refs = try await SessionWorkspace.git(
            ["for-each-ref", "--format=%(refname) %(objectname)"],
            in: fixture.repo
        )
        let status = try await SessionWorkspace.git(["status", "--porcelain"], in: fixture.repo)

        #expect(try await SessionWorkspace.mergeCheck(of: worktree, into: baseBranch) == .blocked(expected))
        await #expect(throws: SessionWorkspace.MergeFailure.blocked(expected)) {
            try await SessionWorkspace.merge(worktree, into: baseBranch, message: "Session")
        }
        #expect(
            try await SessionWorkspace.git(["for-each-ref", "--format=%(refname) %(objectname)"], in: fixture.repo)
                == refs
        )
        #expect(try await SessionWorkspace.git(["status", "--porcelain"], in: fixture.repo) == status)
        if state == "cherry-pick" {
            #expect(FileManager.default.fileExists(atPath: fixture.repo.appending(path: ".git/CHERRY_PICK_HEAD").path))
        }
        if state != "missing" && state != "nothing" {
            #expect(try read("added", in: workspace.workingDirectory) == "session")
            #expect(
                try await SessionWorkspace.git(["status", "--porcelain"], in: workspace.workingDirectory) == "?? added"
            )
        }
    }

    @Test func unresolvedConflictsInTheWorktreeBlockTheMerge() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        let working = workspace.workingDirectory
        try write("session", to: "file", in: working)
        try await SessionWorkspace.git(["add", "file"], in: working)
        try await fixture.commit("Session", in: working)
        try write("base", to: "file", in: fixture.repo)
        try await SessionWorkspace.git(["add", "file"], in: fixture.repo)
        try await fixture.commit("Base", in: fixture.repo)
        // The agent started merging the base into its branch and stopped at the conflict.
        _ = try? await SessionWorkspace.git(
            ["-c", "user.name=T", "-c", "user.email=t@e", "merge", "main"],
            in: working
        )

        #expect(try await SessionWorkspace.mergeCheck(of: worktree, into: "main") == .blocked(.unresolvedConflicts))
    }

    @Test func changesAlreadyOnTheBaseAreNothingToMerge() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        try write("same", to: "added", in: workspace.workingDirectory)
        try write("same", to: "added", in: fixture.repo)
        try await SessionWorkspace.git(["add", "added"], in: fixture.repo)
        try await fixture.commit("Base", in: fixture.repo)
        let base = try await head(fixture.repo)

        await #expect(throws: SessionWorkspace.MergeFailure.blocked(.nothingToMerge)) {
            try await SessionWorkspace.merge(worktree, into: "main", message: "Session")
        }
        try await expectRestored(fixture, at: base)
    }
}
