import Foundation
import Testing

@testable import Workspace

@Suite(.timeLimit(.minutes(1))) struct WorktreeReviewTests {
    @Test func comparesFromMergeBaseAndCombinesWorkingChanges() async throws {
        let fixture = try await ReviewFixture()
        defer { fixture.remove() }
        try fixture.write("initial\n", "edited")
        try fixture.write("deleted\n", "deleted")
        try fixture.write("rename\n", "old")
        try await fixture.commit()
        let base = try await SessionWorkspace.git(["rev-parse", "HEAD"], in: fixture.root)
        try await fixture.git(["branch", "base"])
        try fixture.write("session\n", "committed")
        try await fixture.git(["mv", "old", "renamed"])
        try await fixture.commit()
        try await fixture.git(["checkout", "-q", "base"])
        try fixture.write("base only\n", "base-only")
        try await fixture.commit()
        try await fixture.git(["checkout", "-q", "-"])
        try fixture.write("staged\n", "edited")
        try await fixture.git(["add", "edited"])
        try fixture.write("unstaged\n", "edited")
        try FileManager.default.removeItem(at: fixture.root.appending(path: "deleted"))
        try fixture.write("untracked\n", "space and\nnewline")
        let review = try await SessionWorkspace.review(in: fixture.root, baseBranch: "base", baseRevision: nil)
        #expect(review.baseRevision == base)
        #expect(review.changes.map(\.path) == ["committed", "deleted", "edited", "renamed", "space and\nnewline"])
        #expect(review.changes.map(\.status) == [.added, .deleted, .modified, .renamed, .untracked])
        #expect(review.changes[3].previousPath == "old")
        let data = try await SessionWorkspace.reviewContents(
            in: fixture.root,
            path: "edited",
            revision: review.baseRevision,
            maximumBytes: 1024
        )
        #expect(String(decoding: data, as: UTF8.self) == "initial\n")
    }

    @Test func supportsSelectedSubdirectoriesAndFallbackAndNamesMissingBranches() async throws {
        let fixture = try await ReviewFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "selected"),
            withIntermediateDirectories: true
        )
        try fixture.write("initial", "selected/file")
        try fixture.write("outside", "outside")
        try await fixture.commit()
        let base = try await SessionWorkspace.git(["rev-parse", "HEAD"], in: fixture.root)
        try fixture.write("committed", "selected/file")
        try fixture.write("changed", "outside")
        try await fixture.commit()
        let selected = fixture.root.appending(path: "selected")
        let review = try await SessionWorkspace.review(in: selected, baseBranch: nil, baseRevision: base)
        #expect(review.changes.map(\.path) == ["file"])
        #expect(
            try await SessionWorkspace.reviewContents(in: selected, path: "file", revision: base, maximumBytes: 10)
                == Data("initial".utf8)
        )
        #expect(try await SessionWorkspace.review(in: selected, baseBranch: nil, baseRevision: nil).changes.isEmpty)
        do {
            _ = try await SessionWorkspace.review(in: selected, baseBranch: "missing-branch", baseRevision: base)
            Issue.record("A missing branch must not silently fall back")
        } catch { #expect(error.localizedDescription.contains("missing-branch")) }
        await #expect(throws: (any Error).self) {
            try await SessionWorkspace.reviewContents(in: selected, path: "file", revision: base, maximumBytes: 2)
        }
        await #expect(throws: (any Error).self) {
            try await SessionWorkspace.reviewContents(
                in: selected,
                path: "../outside",
                revision: base,
                maximumBytes: 100
            )
        }
    }
}

private struct ReviewFixture {
    let root: URL
    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "worktree-review-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await SessionWorkspace.git(["init", "-q"], in: root)
    }
    func write(_ text: String, _ path: String) throws {
        try text.write(to: root.appending(path: path), atomically: true, encoding: .utf8)
    }
    func git(_ args: [String]) async throws { try await SessionWorkspace.git(args, in: root) }
    func commit() async throws {
        try await git(["add", "."])
        try await git([
            "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c",
            "core.hooksPath=/dev/null", "commit", "-qm", "Fixture",
        ])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
