import Foundation
import Testing

@testable import Workspace

@Suite(.timeLimit(.minutes(1))) struct WorktreeRemovalTests {
    struct Fixture {
        let directory: URL
        let repo: URL
        let trees: URL

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "worktree-removal-\(UUID())")
            repo = directory.appending(path: "repo")
            trees = directory.appending(path: "trees")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try await SessionWorkspace.git(["init", "-q", "-b", "main"], in: repo)
            try "committed".write(to: repo.appending(path: "file"), atomically: true, encoding: .utf8)
            try await SessionWorkspace.git(["add", "file"], in: repo)
            try await commit("Initial", in: repo)
        }

        func prepare(_ id: UUID = UUID()) async throws -> (SessionWorkspace, SessionWorkspace.Worktree) {
            let workspace = try await SessionWorkspace.prepare(directory: repo, id: id, worktreesRoot: trees)
            let worktree = try #require(
                SessionWorkspace.Worktree(
                    projectDirectory: workspace.projectDirectory,
                    workingDirectory: workspace.workingDirectory,
                    sessionID: id,
                    worktreesRoot: trees
                )
            )
            return (workspace, worktree)
        }

        func commit(_ message: String, in directory: URL) async throws {
            try await SessionWorkspace.git(
                [
                    "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                    "commit", "-qm", message,
                ],
                in: directory
            )
        }

        func branches() async throws -> [String] {
            try await SessionWorkspace.git(["branch", "--format=%(refname:short)"], in: repo)
                .split(separator: "\n").map(String.init)
        }
    }

    @Test(arguments: ["clean", "dirty", "untracked", "committed"])
    func removesExactlyTheSessionWorktreeAndBranch(state: String) async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        let (other, _) = try await fixture.prepare()
        let file = workspace.workingDirectory.appending(path: "file")
        switch state {
        case "dirty": try "changed".write(to: file, atomically: true, encoding: .utf8)
        case "untracked":
            try "new".write(to: workspace.workingDirectory.appending(path: "new"), atomically: true, encoding: .utf8)
        case "committed":
            try "changed".write(to: file, atomically: true, encoding: .utf8)
            try await SessionWorkspace.git(["add", "file"], in: workspace.workingDirectory)
            try await fixture.commit("Work", in: workspace.workingDirectory)
        default: break
        }
        try await SessionWorkspace.remove(worktree)
        #expect(!FileManager.default.fileExists(atPath: worktree.directory.path))
        #expect(FileManager.default.fileExists(atPath: other.workingDirectory.appending(path: "file").path))
        #expect(try String(contentsOf: fixture.repo.appending(path: "file"), encoding: .utf8) == "committed")
        let branches = try await fixture.branches()
        #expect(!branches.contains(worktree.branch))
        #expect(branches.contains("main") && branches.count == 2)
        // A retry after success changes nothing.
        try await SessionWorkspace.remove(worktree)
    }

    @Test func prunesADirectoryDeletedByHand() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (_, worktree) = try await fixture.prepare()
        try FileManager.default.removeItem(at: worktree.directory)
        try await SessionWorkspace.remove(worktree)
        #expect(
            !(try await SessionWorkspace.git(["worktree", "list"], in: fixture.repo)).contains(worktree.directory.path)
        )
        #expect(try await fixture.branches() == ["main"])
    }

    @Test func aMissingWorktreeAndBranchAreNotAnError() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (_, worktree) = try await fixture.prepare()
        try await SessionWorkspace.git(["worktree", "remove", worktree.directory.path], in: fixture.repo)
        try await SessionWorkspace.git(["branch", "-D", worktree.branch], in: fixture.repo)
        try await SessionWorkspace.remove(worktree)
        #expect(!FileManager.default.fileExists(atPath: worktree.directory.path))
    }

    @Test(arguments: ["user-work", "agenthesia/another-session", "detached", "missing-branch"])
    func leavesAWorktreeOffItsSessionBranchInPlace(state: String) async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (_, worktree) = try await fixture.prepare()
        if state == "detached" || state == "missing-branch" {
            try await SessionWorkspace.git(["checkout", "-q", "--detach"], in: worktree.directory)
            if state == "missing-branch" {
                try await SessionWorkspace.git(["branch", "-D", worktree.branch], in: fixture.repo)
            }
        } else {
            try await SessionWorkspace.git(["checkout", "-qb", state], in: worktree.directory)
        }
        let keep = worktree.directory.appending(path: "keep.txt")
        try "uncommitted work".write(to: keep, atomically: true, encoding: .utf8)
        let branches = try await fixture.branches()
        await #expect(throws: SessionWorkspace.WorkspaceError.self) { try await SessionWorkspace.remove(worktree) }
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(try await fixture.branches() == branches)
        #expect(
            try await SessionWorkspace.git(["worktree", "list"], in: fixture.repo).contains(worktree.directory.path)
        )
    }

    @Test func leavesAnUnregisteredDirectoryInPlace() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (_, worktree) = try await fixture.prepare()
        try await SessionWorkspace.git(["worktree", "remove", "--force", worktree.directory.path], in: fixture.repo)
        try FileManager.default.createDirectory(at: worktree.directory, withIntermediateDirectories: true)
        let keep = worktree.directory.appending(path: "keep")
        try "mine".write(to: keep, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await SessionWorkspace.remove(worktree) }
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func refusesSessionsOutsideTheirExpectedWorktree() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let id = UUID()
        let (workspace, worktree) = try await fixture.prepare(id)
        let subdirectory = workspace.workingDirectory.appending(path: "packages/foo")
        #expect(
            SessionWorkspace.Worktree(
                projectDirectory: workspace.projectDirectory,
                workingDirectory: subdirectory,
                sessionID: id,
                worktreesRoot: fixture.trees
            ) == worktree
        )
        // A wrong id, the user's own checkout, a path outside the root, a sibling with the same prefix.
        for (directory, sessionID) in [
            (workspace.workingDirectory, UUID()),
            (workspace.projectDirectory, id),
            (fixture.directory.appending(path: "elsewhere/\(id.uuidString.lowercased())"), id),
            (URL(filePath: workspace.workingDirectory.path + "-copy"), id),
        ] {
            #expect(
                SessionWorkspace.Worktree(
                    projectDirectory: workspace.projectDirectory,
                    workingDirectory: directory,
                    sessionID: sessionID,
                    worktreesRoot: fixture.trees
                ) == nil
            )
        }
        // A non-Git session runs in the selected folder itself.
        let plain = try await SessionWorkspace.prepare(
            directory: fixture.directory,
            id: id,
            worktreesRoot: fixture.trees
        )
        #expect(
            SessionWorkspace.Worktree(
                projectDirectory: plain.projectDirectory,
                workingDirectory: plain.workingDirectory,
                sessionID: id,
                worktreesRoot: fixture.trees
            ) == nil
        )
    }

    @Test func summaryCountsUncommittedPathsAndCommits() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (workspace, worktree) = try await fixture.prepare()
        let base = workspace.baseRevision
        #expect(try await SessionWorkspace.discardSummary(of: worktree, baseRevision: base) == (0, 0))
        let working = workspace.workingDirectory
        for name in ["a", "b"] {
            try name.write(to: working.appending(path: name), atomically: true, encoding: .utf8)
            try await SessionWorkspace.git(["add", name], in: working)
            try await fixture.commit(name, in: working)
        }
        try await SessionWorkspace.git(["mv", "a", "renamed"], in: working)
        try "changed".write(to: working.appending(path: "file"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: working.appending(path: "dir"), withIntermediateDirectories: true)
        for name in ["dir/one", "dir/two"] {
            try name.write(to: working.appending(path: name), atomically: true, encoding: .utf8)
        }
        #expect(try await SessionWorkspace.discardSummary(of: worktree, baseRevision: base) == (4, 2))
        try FileManager.default.removeItem(at: worktree.directory)
        #expect(try await SessionWorkspace.discardSummary(of: worktree, baseRevision: base) == (0, 2))
        #expect(try await SessionWorkspace.discardSummary(of: worktree, baseRevision: nil) == (0, 0))
    }
}
