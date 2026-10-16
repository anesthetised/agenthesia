import Foundation
import Testing

@testable import Workspace

@Suite(.timeLimit(.minutes(1))) struct ChangedPathsTests {
    @Test func includesCommittedStagedUnstagedDeletedAndUntrackedPathsWithinTheSelectedDirectory() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        let selected = fixture.directory.appending(path: "selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        for path in ["selected/deleted", "selected/modified", "outside"] {
            try fixture.write("base", path: path)
        }
        try await fixture.commit()
        let base = try await SessionWorkspace.git(["rev-parse", "HEAD"], in: fixture.directory)
        try fixture.write("committed", path: "selected/modified")
        try await fixture.commit()
        try fixture.write("unstaged", path: "selected/modified")
        try FileManager.default.removeItem(at: selected.appending(path: "deleted"))
        try fixture.write("staged", path: "selected/staged")
        try await SessionWorkspace.git(["add", "selected/staged"], in: fixture.directory)
        try fixture.write("untracked", path: "selected/space and\nnewline.txt")
        try fixture.write("ignored", path: "selected/ignored")
        try fixture.write("ignored\n", path: "selected/.gitignore")
        try fixture.write("changed outside", path: "outside")

        #expect(
            try await SessionWorkspace.changedPaths(in: selected, baseRevision: base)
                == [".gitignore", "deleted", "modified", "space and\nnewline.txt", "staged"]
        )
    }

    @Test func retainsCommittedPathsWhenTheirCurrentContentsWereRestoredToTheBase() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        try fixture.write("base", path: "file")
        try await fixture.commit()
        let base = try await SessionWorkspace.git(["rev-parse", "HEAD"], in: fixture.directory)
        try fixture.write("agent commit", path: "file")
        try await fixture.commit()
        #expect(try await SessionWorkspace.changedPaths(in: fixture.directory, baseRevision: nil).isEmpty)
        try fixture.write("base", path: "file")
        #expect(try await SessionWorkspace.changedPaths(in: fixture.directory, baseRevision: base) == ["file"])
        #expect(try await SessionWorkspace.changedPaths(in: fixture.directory, baseRevision: nil) == ["file"])
    }

    @Test func includesStagedChangesEvenWhenWorkingContentsMatchHEAD() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        try fixture.write("base", path: "file")
        try await fixture.commit()
        try fixture.write("staged", path: "file")
        try await SessionWorkspace.git(["add", "file"], in: fixture.directory)
        try fixture.write("base", path: "file")
        #expect(try await SessionWorkspace.changedPaths(in: fixture.directory, baseRevision: nil) == ["file"])
    }

    @Test func reportsBothSidesOfRenamesAndUsesTheMergeBaseAfterDivergence() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        try fixture.write("base", path: "old")
        try await fixture.commit()
        try await SessionWorkspace.git(["branch", "original"], in: fixture.directory)
        try fixture.write("source branch", path: "source-only")
        try await fixture.commit()
        let base = try await SessionWorkspace.git(["rev-parse", "HEAD"], in: fixture.directory)
        try await SessionWorkspace.git(["checkout", "-q", "original"], in: fixture.directory)
        try FileManager.default.moveItem(
            at: fixture.directory.appending(path: "old"),
            to: fixture.directory.appending(path: "new")
        )
        try await fixture.commit()
        #expect(try await SessionWorkspace.changedPaths(in: fixture.directory, baseRevision: base) == ["new", "old"])
    }

    @Test func skipsChangedNamesThatAreNotUTF8() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        try fixture.write("base", path: "file")
        try await fixture.commit()
        try fixture.write("changed", path: "file")
        try await stageNonUTF8Path(in: fixture.directory)
        #expect(try await SessionWorkspace.changedPaths(in: fixture.directory, baseRevision: nil) == ["file"])
    }

    @Test func distinguishesNonGitBrokenGitAndBareRepositories() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "changed-paths-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await SessionWorkspace.repositoryRoot(in: directory) == nil)
        #expect(try await SessionWorkspace.watchDirectories(in: directory) == [directory.resolvingSymlinksInPath()])
        await #expect(throws: (any Error).self) {
            try await SessionWorkspace.changedPaths(in: directory, baseRevision: nil)
        }
        try "gitdir: missing".write(to: directory.appending(path: ".git"), atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await SessionWorkspace.repositoryRoot(in: directory) }
        try FileManager.default.removeItem(at: directory.appending(path: ".git"))
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: ".git"),
            withDestinationURL: directory.appending(path: "missing")
        )
        await #expect(throws: (any Error).self) { try await SessionWorkspace.repositoryRoot(in: directory) }
        try FileManager.default.removeItem(at: directory.appending(path: ".git"))
        try await SessionWorkspace.git(["init", "--bare", "-q"], in: directory)
        await #expect(throws: (any Error).self) { try await SessionWorkspace.repositoryRoot(in: directory) }
    }

    @Test func watchesLinkedWorktreeGitMetadataAndHonorsCancellationAndInvalidBaselines() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        try fixture.write("base", path: "file")
        try await fixture.commit()
        let trees = fixture.directory.deletingLastPathComponent().appending(path: "trees-\(UUID())")
        defer { try? FileManager.default.removeItem(at: trees) }
        let session = try await SessionWorkspace.prepare(directory: fixture.directory, id: UUID(), worktreesRoot: trees)
        let roots = try await SessionWorkspace.watchDirectories(in: session.workingDirectory)
        #expect(roots.contains(session.workingDirectory))
        #expect(roots.contains(fixture.directory.appending(path: ".git").resolvingSymlinksInPath()))
        #expect(try await SessionWorkspace.repositoryRoot(in: session.workingDirectory) == session.workingDirectory)
        for base in ["bad-revision", String(repeating: "f", count: 40)] {
            await #expect(throws: (any Error).self) {
                try await SessionWorkspace.changedPaths(in: session.workingDirectory, baseRevision: base)
            }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SessionWorkspace.changedPaths(in: session.workingDirectory, baseRevision: nil)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @MainActor @Test func observesGitMetadataOutsideTheSelectedWorktreeDirectory() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        let selected = fixture.directory.appending(path: "selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try fixture.write("base", path: "selected/file")
        try await fixture.commit()
        let base = try await SessionWorkspace.git(["rev-parse", "HEAD"], in: fixture.directory)
        let trees = fixture.directory.deletingLastPathComponent().appending(path: "trees-\(UUID())")
        defer { try? FileManager.default.removeItem(at: trees) }
        let session = try await SessionWorkspace.prepare(directory: selected, id: UUID(), worktreesRoot: trees)
        let roots = try await SessionWorkspace.watchDirectories(in: session.workingDirectory)
        var invalidations = 0
        let watcher = try DirectoryWatcher(directories: roots) { invalidations += 1 }
        defer { watcher.close() }
        // Only a ref in the main checkout changes; the selected worktree directory is untouched.
        try fixture.write(base + "\n", path: ".git/refs/heads/watcher-fixture")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while invalidations == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(invalidations > 0)
        #expect(try await SessionWorkspace.changedPaths(in: session.workingDirectory, baseRevision: nil).isEmpty)
    }
}

private struct ChangedPathsFixture: Sendable {
    let directory: URL

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "changed-paths-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await SessionWorkspace.git(["init", "-q"], in: directory)
    }

    func write(_ content: String, path: String) throws {
        try content.write(to: directory.appending(path: path), atomically: true, encoding: .utf8)
    }

    func commit() async throws {
        try await SessionWorkspace.git(["add", "."], in: directory)
        try await SessionWorkspace.git(
            [
                "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                "commit", "-qm", "Fixture",
            ],
            in: directory
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
