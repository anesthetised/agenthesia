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
        try SessionWorkspace.git(["init", "-q"], in: repo)
        try "committed".write(to: repo.appending(path: "file"), atomically: true, encoding: .utf8)
        try SessionWorkspace.git(["add", "file"], in: repo)
        try SessionWorkspace.git(
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
            try SessionWorkspace.git(["branch", "--show-current"], in: result.workingDirectory).hasPrefix("agenthesia/")
        )
    }

    @Test func nonRepositoryUsesSelectedDirectoryAndEmptyRepositoryFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "worktree-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await SessionWorkspace.prepare(directory: directory, id: UUID())
        #expect(result.workingDirectory == directory.resolvingSymlinksInPath())
        try SessionWorkspace.git(["init", "-q"], in: directory)
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
        try SessionWorkspace.git(["init", "-q"], in: repo)
        try "committed".write(to: package.appending(path: "file"), atomically: true, encoding: .utf8)
        try SessionWorkspace.git(["add", "."], in: repo)
        try SessionWorkspace.git(
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

    @Test func gitErrorsComeFromStandardError() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "worktree-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) { try SessionWorkspace.git(["rev-parse", "--show-toplevel"], in: directory) }
        do { try SessionWorkspace.git(["rev-parse", "--show-toplevel"], in: directory) } catch {
            #expect(error.localizedDescription.contains("not a git repository"))
        }
    }
}
