import Foundation
import Observation
import Persistence
import Synchronization
import Testing

@testable import AgenthesiaCore
@testable import Workspace

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionReviewTests {
    @Test func readsBothSidesAndRetainsSelectionAcrossRefresh() async throws {
        let fixture = try await SessionReviewFixture()
        defer { fixture.remove() }
        try fixture.write("old\n", "file")
        try fixture.write("deleted\n", "deleted")
        try await fixture.commit()
        try fixture.write("new\n", "file")
        try FileManager.default.removeItem(at: fixture.root.appending(path: "deleted"))
        try Data([0, 1, 2]).write(to: fixture.root.appending(path: "binary"))
        let review = SessionReview(session: fixture.session, root: fixture.root)
        await review.refresh()
        #expect(review.error == nil)
        #expect(review.changes.map(\.path) == ["binary", "deleted", "file"])
        review.selectedPath = "file"
        await review.loadSelection()
        #expect(review.document?.old == "old\n")
        #expect(review.document?.new == "new\n")
        try fixture.write("updated\n", "file")
        await review.refresh()
        #expect(review.error == nil)
        #expect(review.selectedPath == "file")
        await review.loadSelection()
        #expect(review.document?.new == "updated\n")
        review.selectedPath = "deleted"
        await review.loadSelection()
        #expect(review.document?.old == "deleted\n")
        #expect(review.document?.new == "")
        review.selectedPath = "binary"
        await review.loadSelection()
        #expect(review.document == nil)
        #expect(review.documentError == SessionFileDocument.Failure.notText.localizedDescription)
        try fixture.write("old\n", "file")
        await review.refresh()
        #expect(review.selectedPath == "binary")
        review.selectedPath = "file"
        await review.refresh()
        #expect(review.selectedPath == "binary")
    }

    /// ADR-0041: a refresh compares before it replaces, so an unchanged file does not touch the shown document.
    @Test func anUnchangedFileLeavesTheDocumentUntouched() async throws {
        let fixture = try await SessionReviewFixture()
        defer { fixture.remove() }
        try fixture.write("kept\n", "kept")
        try await fixture.commit()
        try fixture.write("one\n", "file")
        let review = SessionReview(session: fixture.session, root: fixture.root)
        await review.refresh()
        await review.loadSelection()
        let shown = try #require(review.document)
        let touched = Mutex(false)
        withObservationTracking {
            _ = review.document
            _ = review.documentError
            _ = review.isHolding
        } onChange: {
            touched.withLock { $0 = true }
        }
        try fixture.write("other\n", "second")
        await review.refresh()
        await review.loadSelection()
        #expect(review.changes.map(\.path) == ["file", "second"])
        #expect(!touched.withLock { $0 })
        #expect(review.document == shown && !review.isHolding)
    }

    @Test func aSelectionHoldsAChangedFileUntilShowLatestOrItEnds() async throws {
        let fixture = try await SessionReviewFixture()
        defer { fixture.remove() }
        try fixture.write("kept\n", "kept")
        try await fixture.commit()
        try fixture.write("one\n", "file")
        let review = SessionReview(session: fixture.session, root: fixture.root)
        await review.refresh()
        await review.loadSelection()
        review.hasSelection = true
        try fixture.write("two\n", "file")
        await review.refresh()
        await review.loadSelection()
        #expect(review.document?.new == "one\n" && review.isHolding)
        review.showLatest()
        #expect(review.document?.new == "two\n" && !review.isHolding)
        // Changing back to what is shown is no longer a change.
        try fixture.write("three\n", "file")
        await review.refresh()
        await review.loadSelection()
        #expect(review.isHolding)
        try fixture.write("two\n", "file")
        await review.refresh()
        await review.loadSelection()
        #expect(review.document?.new == "two\n" && !review.isHolding)
        try fixture.write("four\n", "file")
        await review.refresh()
        await review.loadSelection()
        #expect(review.isHolding)
        review.hasSelection = false
        #expect(review.document?.new == "four\n" && !review.isHolding)
    }

    @Test func aHeldFileThatLeavesTheListStaysUntilShowLatest() async throws {
        let fixture = try await SessionReviewFixture()
        defer { fixture.remove() }
        try fixture.write("base\n", "file")
        try await fixture.commit()
        try fixture.write("changed\n", "file")
        try fixture.write("other\n", "second")
        let review = SessionReview(session: fixture.session, root: fixture.root)
        await review.refresh()
        await review.loadSelection()
        #expect(review.selectedPath == "file")
        review.hasSelection = true
        try fixture.write("base\n", "file")
        await review.refresh()
        #expect(review.changes.map(\.path) == ["second"])
        #expect(review.selectedPath == "file")
        await review.loadSelection()
        #expect(review.document?.new == "changed\n" && review.isHolding)
        review.showLatest()
        #expect(review.selectedPath == "second" && review.document == nil)
        await review.loadSelection()
        #expect(review.document?.new == "other\n")
    }

    @Test func selectingAnotherFileReplacesTheDiffDespiteASelection() async throws {
        let fixture = try await SessionReviewFixture()
        defer { fixture.remove() }
        try fixture.write("kept\n", "kept")
        try await fixture.commit()
        try fixture.write("one\n", "file")
        try fixture.write("other\n", "second")
        let review = SessionReview(session: fixture.session, root: fixture.root)
        await review.refresh()
        await review.loadSelection()
        review.hasSelection = true
        review.selectedPath = "second"
        await review.loadSelection()
        #expect(review.document?.path == "second" && !review.isHolding)
    }

    @Test(arguments: [Data([0, 1]), Data([0xFF])])
    func rejectsHistoricalBinaryAndInvalidUTF8(_ contents: Data) async throws {
        let fixture = try await SessionReviewFixture()
        defer { fixture.remove() }
        try contents.write(to: fixture.root.appending(path: "file"))
        try await fixture.commit()
        try fixture.write("text", "file")
        let review = SessionReview(session: fixture.session, root: fixture.root)
        await review.refresh()
        await review.loadSelection()
        #expect(review.document == nil)
        #expect(review.documentError == SessionFileDocument.Failure.notText.localizedDescription)
    }

    @Test func markingUnmarkingAndAdvancingToTheNextUnviewedFile() async throws {
        let fixture = try await SessionReviewFixture()
        defer { fixture.remove() }
        try fixture.write("kept\n", "kept")
        try await fixture.commit()
        for name in ["a", "b", "c"] { try fixture.write("\(name)\n", name) }
        let review = SessionReview(session: fixture.session, root: fixture.root)
        await review.refresh()
        #expect(review.selectedPath == "a" && review.viewedCount == 0)
        review.toggleViewed("b")
        #expect(review.viewed.isViewed("b") && review.viewedCount == 1)
        review.toggleViewed("b")
        #expect(!review.viewed.isViewed("b") && review.viewedCount == 0)
        review.toggleViewed("missing")
        #expect(review.viewedCount == 0)
        review.toggleViewed("b")
        review.markSelectedViewedAndAdvance()
        #expect(review.viewed.isViewed("a") && review.selectedPath == "c")
        review.markSelectedViewedAndAdvance()
        #expect(review.viewedCount == 3 && review.selectedPath == "c")
        // Marking again does not unmark.
        review.markSelectedViewedAndAdvance()
        #expect(review.viewedCount == 3)
        review.toggleViewed("a")
        review.selectedPath = "c"
        review.markSelectedViewedAndAdvance()
        #expect(review.selectedPath == "a" && review.viewedCount == 2)
    }

    @Test func aMarkClearsWhenTheFileChangesAndStaysWhenItDoesNot() async throws {
        let fixture = try await SessionReviewFixture()
        defer { fixture.remove() }
        try fixture.write("tracked\n", "tracked")
        try await fixture.commit()
        try fixture.write("one\n", "file")
        try fixture.write("edited\n", "tracked")
        try fixture.write("other\n", "other")
        let review = SessionReview(session: fixture.session, root: fixture.root)
        await review.refresh()
        review.toggleViewed("file")
        review.toggleViewed("tracked")
        await review.refresh()
        #expect(review.viewed.isViewed("file") && review.viewed.isViewed("tracked") && review.viewedCount == 2)
        // A new file elsewhere in the list changes nothing for the viewed ones.
        try fixture.write("late\n", "late")
        await review.refresh()
        #expect(review.viewedCount == 2)
        try fixture.write("two\n", "file")
        await review.refresh()
        #expect(!review.viewed.isViewed("file") && review.viewed.isViewed("tracked") && review.viewedCount == 1)
        // The file leaves the list, so its mark does not come back with it.
        review.toggleViewed("file")
        try FileManager.default.removeItem(at: fixture.root.appending(path: "file"))
        await review.refresh()
        try fixture.write("two\n", "file")
        await review.refresh()
        #expect(!review.viewed.isViewed("file") && review.viewedCount == 1)
    }

    @Test func marksOutliveTheReviewThatSetThem() async throws {
        let fixture = try await SessionReviewFixture()
        defer { fixture.remove() }
        try fixture.write("kept\n", "kept")
        try await fixture.commit()
        try fixture.write("one\n", "file")
        let marks = ViewedMarks()
        let first = SessionReview(session: fixture.session, root: fixture.root, viewed: marks)
        await first.refresh()
        first.toggleViewed("file")
        let second = SessionReview(session: fixture.session, root: fixture.root, viewed: marks)
        await second.refresh()
        #expect(second.viewedCount == 1)
    }

    @Test func countsLinesAgainstTheReviewsBase() async throws {
        let fixture = try await SessionReviewFixture()
        defer { fixture.remove() }
        try fixture.write("1\n2\n3\n", "edited")
        try fixture.write("gone\n", "gone")
        try await fixture.commit()
        try fixture.write("1\nx\n3\n4\n", "edited")
        try FileManager.default.removeItem(at: fixture.root.appending(path: "gone"))
        try fixture.write("a\nb\n", "untracked")
        try Data([0, 1]).write(to: fixture.root.appending(path: "binary"))
        let review = SessionReview(session: fixture.session, root: fixture.root)
        #expect(review.stats == ChangeStats())
        await review.refresh()
        #expect(review.stats.files["edited"] == ChangeStats.Lines(added: 2, removed: 1))
        #expect(review.stats.files["gone"] == ChangeStats.Lines(added: 0, removed: 1))
        #expect(review.stats.files["untracked"] == ChangeStats.Lines(added: 2, removed: 0))
        #expect(review.stats.binary == ["binary"])
        try fixture.write("1\nx\n3\n", "edited")
        await review.refresh()
        #expect(review.stats.files["edited"] == ChangeStats.Lines(added: 1, removed: 1))
    }

    /// ADR-0043: in the project folder the branch is the checkout itself, so the review compares with the session's
    /// start, commits made since included, and says so.
    @Test func aProjectFolderSessionComparesWithItsStart() async throws {
        let fixture = try await SessionReviewFixture()
        defer { fixture.remove() }
        try await fixture.git(["checkout", "-q", "-b", "main"])
        try fixture.write("old\n", "file")
        try await fixture.commit()
        let start = try await SessionWorkspace.git(["rev-parse", "HEAD"], in: fixture.root)
        try fixture.write("committed\n", "committed")
        try await fixture.commit()
        try fixture.write("new\n", "file")
        let session = SessionRecord(
            projectID: UUID(),
            agentInstallID: UUID(),
            workingDirectory: fixture.root.path,
            baseRevision: start,
            baseBranch: "main"
        )
        let worktree = SessionReview(session: session, root: fixture.root)
        #expect(worktree.title == "Changes against main")
        let review = SessionReview(session: session, root: fixture.root, inProjectFolder: true)
        #expect(review.title == "Changes since the session started")
        #expect(review.baseBranch == nil)
        await review.refresh()
        #expect(review.error == nil)
        #expect(review.changes.map(\.path) == ["committed", "file"])
        #expect(SessionReview(session: fixture.session, root: fixture.root).title == "Session changes")
    }

    @Test func rejectsOversizedHistoricalFilesAndOutsideSymlinksAndReplacedRoots() async throws {
        let fixture = try await SessionReviewFixture()
        defer { fixture.remove() }
        try fixture.write(String(repeating: "a", count: SessionFileDocument.maximumBytes + 1), "large")
        try await fixture.commit()
        try fixture.write("small", "large")
        let review = SessionReview(session: fixture.session, root: fixture.root)
        await review.refresh()
        await review.loadSelection()
        #expect(review.documentError == SessionFileDocument.Failure.tooLarge.localizedDescription)
        let outside = fixture.root.deletingLastPathComponent().appending(path: "outside-review-\(UUID())")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appending(path: "link"),
            withDestinationURL: outside
        )
        await review.refresh()
        review.selectedPath = "link"
        await review.loadSelection()
        #expect(review.document == nil)
        #expect(review.documentError == SessionFileDocument.Failure.outsideScope.localizedDescription)
        let original = fixture.root.appendingPathExtension("original")
        try FileManager.default.moveItem(at: fixture.root, to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: original)
        await review.refresh()
        #expect(review.changes.isEmpty)
        #expect(review.error == SessionFileDocument.Failure.outsideScope.localizedDescription)
    }
}

struct SessionReviewFixture {
    let root: URL
    var session: SessionRecord { SessionRecord(projectID: UUID(), agentInstallID: UUID(), workingDirectory: root.path) }
    init() async throws {
        root =
            ScopedFileAccess(roots: [FileManager.default.temporaryDirectory.appending(path: "session-review-\(UUID())")]
            ).roots[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await git(["init", "-q"])
    }
    func write(_ text: String, _ path: String) throws {
        try text.write(to: root.appending(path: path), atomically: true, encoding: .utf8)
    }
    func git(_ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(
                    with: Result {
                        let process = Process()
                        process.executableURL = URL(filePath: "/usr/bin/git")
                        process.arguments =
                            [
                                "-C", root.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c",
                                "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                            ] + args
                        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                        process.standardOutput = FileHandle.nullDevice
                        process.standardError = FileHandle.nullDevice
                        try process.run()
                        process.waitUntilExit()
                        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                    }
                )
            }
        }
    }
    func commit() async throws { try await git(["add", "."]); try await git(["commit", "-qm", "Fixture"]) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
