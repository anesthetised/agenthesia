import Foundation
import Testing

@testable import AgenthesiaCore
@testable import Workspace

@MainActor @Suite(.timeLimit(.minutes(1))) struct ViewedMarksTests {
    typealias Change = SessionWorkspace.Review.Change

    private func fingerprint(
        _ status: Change.Status = .modified,
        size: Int? = 4,
        modified: TimeInterval = 100
    ) -> ViewedMarks.Fingerprint {
        .init(status: status, size: size, modified: Date(timeIntervalSince1970: modified))
    }

    private func changes(_ paths: String...) -> [Change] {
        paths.map { Change(path: $0, previousPath: nil, status: .modified) }
    }

    @Test func aMarkSurvivesOnlyWhileStatusSizeAndModificationTimeAreTheSame() {
        let marks = ["a": fingerprint()]
        #expect(ViewedMarks.surviving(marks, current: ["a": fingerprint()]) == marks)
        #expect(ViewedMarks.surviving(marks, current: ["a": fingerprint(.added)]).isEmpty)
        #expect(ViewedMarks.surviving(marks, current: ["a": fingerprint(size: 5)]).isEmpty)
        #expect(ViewedMarks.surviving(marks, current: ["a": fingerprint(modified: 101)]).isEmpty)
        // A file that left the list loses its mark too.
        #expect(ViewedMarks.surviving(marks, current: [:]).isEmpty)
    }

    @Test func aDeletedFileHasAStableFingerprint() {
        let gone = ViewedMarks.Fingerprint(status: .deleted, size: nil, modified: nil)
        #expect(ViewedMarks.surviving(["a": gone], current: ["a": gone]) == ["a": gone])
    }

    @Test func marksAndUnmarksCountOnlyListedFiles() {
        let marks = ViewedMarks()
        marks.mark("a", as: fingerprint())
        marks.mark("gone", as: fingerprint())
        #expect(marks.isViewed("a") && !marks.isViewed("b"))
        #expect(marks.count(in: changes("a", "b")) == 1)
        marks.unmark("a")
        #expect(!marks.isViewed("a") && marks.count(in: changes("a", "b")) == 0)
    }

    @Test func nextUnviewedWrapsRoundAndSkipsViewedFiles() {
        let marks = ViewedMarks()
        let list = changes("a", "b", "c", "d")
        marks.mark("b", as: fingerprint())
        marks.mark("a", as: fingerprint())
        #expect(marks.nextUnviewed(after: "a", in: list) == "c")
        #expect(marks.nextUnviewed(after: "d", in: list) == "c")
        #expect(marks.nextUnviewed(after: nil, in: list) == "c")
        #expect(marks.nextUnviewed(after: "gone", in: list) == "c")
        marks.mark("c", as: fingerprint())
        #expect(marks.nextUnviewed(after: "c", in: list) == "d")
        marks.mark("d", as: fingerprint())
        #expect(marks.nextUnviewed(after: "d", in: list) == nil)
        #expect(ViewedMarks().nextUnviewed(after: nil, in: []) == nil)
    }

    @Test func keepDropsChangedMarksAndReadsFingerprintsFromDisk() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "viewed-marks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "file")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        let change = Change(path: "file", previousPath: nil, status: .untracked)
        let read = ViewedMarks.Fingerprint.read(change, in: root)
        #expect(read.size == 4 && read.status == .untracked && read.modified != nil)
        let marks = ViewedMarks()
        marks.mark("file", as: read)
        marks.keep(matching: ["file": read])
        #expect(marks.isViewed("file"))
        try "three\n".write(to: file, atomically: true, encoding: .utf8)
        marks.keep(matching: ["file": .read(change, in: root)])
        #expect(!marks.isViewed("file"))
        let missing = ViewedMarks.Fingerprint.read(Change(path: "none", previousPath: nil, status: .deleted), in: root)
        #expect(missing.size == nil && missing.modified == nil)
    }
}
