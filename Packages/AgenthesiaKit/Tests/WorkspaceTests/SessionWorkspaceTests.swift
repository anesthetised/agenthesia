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
}
