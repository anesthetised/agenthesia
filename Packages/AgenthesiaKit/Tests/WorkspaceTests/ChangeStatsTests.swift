import Foundation
import Testing

@testable import Workspace

@Suite(.timeLimit(.minutes(1))) struct ChangeStatsTests {
    @Test func countsModifiedAddedDeletedAndUntrackedFilesAgainstTheBase() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        try fixture.write("one\ntwo\nthree\n", path: "modified")
        try fixture.write("a\nb\n", path: "deleted")
        try await fixture.commit()
        let base = try await SessionWorkspace.git(["rev-parse", "HEAD"], in: fixture.directory)
        try fixture.write("one\nTWO\nthree\nfour\n", path: "modified")
        try await fixture.commit()
        try FileManager.default.removeItem(at: fixture.directory.appending(path: "deleted"))
        try fixture.write("x\ny\nz", path: "staged")
        try await SessionWorkspace.git(["add", "staged"], in: fixture.directory)
        try fixture.write("1\n2\n", path: "untracked")
        try fixture.write("", path: "empty")

        let stats = try await SessionWorkspace.changeStats(in: fixture.directory, baseRevision: base)

        #expect(
            stats.files == [
                "modified": .init(added: 2, removed: 1),
                "deleted": .init(added: 0, removed: 2),
                "staged": .init(added: 3, removed: 0),
                "untracked": .init(added: 2, removed: 0),
            ]
        )
        #expect(stats.binary.isEmpty)
        #expect(stats.total == .init(added: 7, removed: 3))
    }

    @Test func countsARenameAsADeletionAndAnAddition() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        try fixture.write("a\nb\n", path: "old")
        try await fixture.commit()
        try FileManager.default.moveItem(
            at: fixture.directory.appending(path: "old"),
            to: fixture.directory.appending(path: "new")
        )
        try await SessionWorkspace.git(["add", "-A"], in: fixture.directory)

        let stats = try await SessionWorkspace.changeStats(in: fixture.directory, baseRevision: nil)

        #expect(stats.files == ["old": .init(added: 0, removed: 2), "new": .init(added: 2, removed: 0)])
    }

    @Test func leavesBinaryFilesOutOfTheTotals() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        try Data([0, 1, 2]).write(to: fixture.directory.appending(path: "tracked.bin"))
        try fixture.write("text\n", path: "text")
        try await fixture.commit()
        try Data([0, 1, 2, 3]).write(to: fixture.directory.appending(path: "tracked.bin"))
        try Data([0, 9]).write(to: fixture.directory.appending(path: "untracked.bin"))
        try fixture.write("text\nmore\n", path: "text")

        let stats = try await SessionWorkspace.changeStats(in: fixture.directory, baseRevision: nil)

        #expect(stats.binary == ["tracked.bin", "untracked.bin"])
        #expect(stats.files == ["text": .init(added: 1, removed: 0)])
        #expect(stats.total == .init(added: 1, removed: 0))
    }

    @Test func withoutABaseCountsOnlyWorkingChangesAndUsesPathsRelativeToTheSelectedDirectory() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        let selected = fixture.directory.appending(path: "selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try fixture.write("base\n", path: "selected/file")
        try fixture.write("base\n", path: "outside")
        try await fixture.commit()
        try fixture.write("base\nedit\n", path: "selected/file")
        try fixture.write("changed\n", path: "outside")
        try fixture.write("new line", path: "selected/new")

        let stats = try await SessionWorkspace.changeStats(in: selected, baseRevision: nil)

        #expect(stats.files == ["file": .init(added: 1, removed: 0), "new": .init(added: 1, removed: 0)])
    }

    @Test func omitsAPathWhoseContentsWereRestoredToTheBase() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        try fixture.write("base\n", path: "file")
        try await fixture.commit()
        let base = try await SessionWorkspace.git(["rev-parse", "HEAD"], in: fixture.directory)
        try fixture.write("agent\n", path: "file")
        try await fixture.commit()
        try fixture.write("base\n", path: "file")

        #expect(try await SessionWorkspace.changeStats(in: fixture.directory, baseRevision: base) == ChangeStats())
    }

    @Test func ignoresIgnoredFilesAndReportsDirectoriesAsWithoutCounts() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        try fixture.write("ignored\n", path: ".gitignore")
        try fixture.write("base\n", path: "file")
        try await fixture.commit()
        try fixture.write("x\n", path: "ignored")
        // A nested repository is listed as a directory entry, which has no lines to count.
        let nested = fixture.directory.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try await SessionWorkspace.git(["init", "-q"], in: nested)
        try fixture.write("inner\n", path: "nested/inner")

        let stats = try await SessionWorkspace.changeStats(in: fixture.directory, baseRevision: nil)

        #expect(stats.files.isEmpty)
        #expect(stats.binary == ["nested/"])
    }

    @Test func rejectsAMalformedBaseAndANonGitDirectory() async throws {
        let fixture = try await ChangedPathsFixture()
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) {
            try await SessionWorkspace.changeStats(in: fixture.directory, baseRevision: "not-a-revision")
        }
        let plain = FileManager.default.temporaryDirectory.appending(path: "change-stats-plain-\(UUID())")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        await #expect(throws: (any Error).self) {
            try await SessionWorkspace.changeStats(in: plain, baseRevision: nil)
        }
    }
}
