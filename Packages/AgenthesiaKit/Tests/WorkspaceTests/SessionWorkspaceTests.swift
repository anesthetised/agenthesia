import Foundation
import Testing

@testable import Workspace

@Suite(.timeLimit(.minutes(1))) struct SessionWorkspaceTests {
    @Test func isolatesCommittedFilesAndPreservesOriginalChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "worktree-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appending(path: "repo with spaces")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await SessionWorkspace.git(["init", "-q"], in: repo)
        try "committed".write(to: repo.appending(path: "file"), atomically: true, encoding: .utf8)
        try await SessionWorkspace.git(["add", "file"], in: repo)
        try await SessionWorkspace.git(
            [
                "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "commit",
                "-qm", "Initial",
            ],
            in: repo
        )
        try "dirty".write(to: repo.appending(path: "file"), atomically: true, encoding: .utf8)
        let result = try await SessionWorkspace.prepare(
            directory: repo,
            id: UUID(),
            worktreesRoot: directory.appending(path: "trees")
        )
        #expect(result.projectDirectory == repo.resolvingSymlinksInPath())
        #expect(result.workingDirectory != result.projectDirectory)
        await #expect(throws: (any Error).self) {
            try await SessionWorkspace.prepare(
                directory: repo,
                id: UUID(),
                worktreesRoot: repo.appending(path: "nested")
            )
        }
        #expect(try String(contentsOf: result.workingDirectory.appending(path: "file"), encoding: .utf8) == "committed")
        #expect(try String(contentsOf: repo.appending(path: "file"), encoding: .utf8) == "dirty")
        #expect(
            try await SessionWorkspace.git(["branch", "--show-current"], in: result.workingDirectory)
                .hasPrefix("agenthesia/")
        )
    }

    @Test func nonRepositoryUsesSelectedDirectoryAndEmptyRepositoryFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "worktree-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await SessionWorkspace.prepare(directory: directory, id: UUID())
        #expect(result.workingDirectory == directory.resolvingSymlinksInPath())
        try await SessionWorkspace.git(["init", "-q"], in: directory)
        await #expect(throws: (any Error).self) {
            try await SessionWorkspace.prepare(
                directory: directory,
                id: UUID(),
                worktreesRoot: directory.appending(path: "trees")
            )
        }
    }

    @Test func keepsTheSelectedSubdirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "worktree-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appending(path: "repo")
        let package = repo.appending(path: "packages/foo")
        let untracked = repo.appending(path: "untracked")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untracked, withIntermediateDirectories: true)
        try await SessionWorkspace.git(["init", "-q"], in: repo)
        try "committed".write(to: package.appending(path: "file"), atomically: true, encoding: .utf8)
        try await SessionWorkspace.git(["add", "."], in: repo)
        try await SessionWorkspace.git(
            [
                "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "commit",
                "-qm", "Initial",
            ],
            in: repo
        )
        let trees = directory.appending(path: "trees")
        let result = try await SessionWorkspace.prepare(directory: package, id: UUID(), worktreesRoot: trees)
        #expect(result.projectDirectory == repo.resolvingSymlinksInPath())
        #expect(result.workingDirectory.lastPathComponent == "foo")
        #expect(
            try String(contentsOf: result.workingDirectory.appending(path: "file"), encoding: .utf8) == "committed"
        )
        await #expect(throws: (any Error).self) {
            try await SessionWorkspace.prepare(directory: untracked, id: UUID(), worktreesRoot: trees)
        }
    }

    @Test(arguments: ["externalSymlink", "file", "internalSymlink"])
    func validatesSelectedDirectoryAtHEAD(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "worktree-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appending(path: "repo")
        let selected = repo.appending(path: "selected")
        let internalTarget = repo.appending(path: "target")
        let outside = directory.appending(path: "outside")
        try FileManager.default.createDirectory(at: internalTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "committed".write(to: internalTarget.appending(path: "file"), atomically: true, encoding: .utf8)
        if kind == "file" {
            try "file".write(to: selected, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.createSymbolicLink(
                atPath: selected.path,
                withDestinationPath: kind == "externalSymlink" ? outside.path : "target"
            )
        }
        try await SessionWorkspace.git(["init", "-q"], in: repo)
        try await SessionWorkspace.git(["add", "."], in: repo)
        try await SessionWorkspace.git(
            [
                "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                "commit", "-qm", "Initial",
            ],
            in: repo
        )
        // The selected directory can differ from the file or symlink committed at HEAD.
        try FileManager.default.removeItem(at: selected)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let trees = directory.appending(path: "trees")
        if kind == "internalSymlink" {
            let result = try await SessionWorkspace.prepare(directory: selected, id: UUID(), worktreesRoot: trees)
            #expect(result.workingDirectory.lastPathComponent == "target")
            #expect(
                try String(contentsOf: result.workingDirectory.appending(path: "file"), encoding: .utf8) == "committed"
            )
        } else {
            await #expect(throws: SessionWorkspace.WorkspaceError.self) {
                try await SessionWorkspace.prepare(directory: selected, id: UUID(), worktreesRoot: trees)
            }
        }
    }

    @Test func gitErrorsComeFromStandardError() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "worktree-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await SessionWorkspace.git(["rev-parse", "--show-toplevel"], in: directory)
            Issue.record("Expected Git to fail outside a repository")
        } catch {
            #expect(error.localizedDescription.contains("not a git repository"))
        }
    }
}
