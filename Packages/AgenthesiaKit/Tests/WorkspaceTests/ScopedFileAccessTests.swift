import Darwin
import Foundation
import Testing

@testable import Workspace

@Suite struct ScopedFileAccessTests {
    let root: URL
    let outside: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ScopedFileAccessTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        root = base.appending(path: "root")
        outside = base.appending(path: "outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "one\ntwo\nthree\nfour".write(to: root.appending(path: "lines.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appending(path: "secret.txt"), atomically: true, encoding: .utf8)
    }

    private var access: ScopedFileAccess { ScopedFileAccess(roots: [root]) }

    private func path(_ relative: String) -> String {
        root.appending(path: relative).path(percentEncoded: false)
    }

    @Test func readsWholeFilesAndLineRanges() throws {
        #expect(try access.readText(at: path("lines.txt")) == "one\ntwo\nthree\nfour")
        #expect(try access.readText(at: path("lines.txt"), line: 2) == "two\nthree\nfour")
        #expect(try access.readText(at: path("lines.txt"), line: 2, limit: 2) == "two\nthree")
        #expect(try access.readText(at: path("lines.txt"), limit: 1) == "one")
        #expect(try access.readText(at: path("lines.txt"), line: 10) == "")
        #expect(try access.readText(at: path("lines.txt"), line: 0, limit: 0) == "")
    }

    @Test func writesFilesAndCreatesDirectories() throws {
        try access.writeText("new", to: path("nested/dir/file.txt"))
        #expect(try String(contentsOf: root.appending(path: "nested/dir/file.txt"), encoding: .utf8) == "new")
        try access.writeText("replaced", to: path("lines.txt"))
        #expect(try access.readText(at: path("lines.txt")) == "replaced")
    }

    @Test func rejectsPathsOutsideTheRoots() throws {
        let secret = outside.appending(path: "secret.txt").path(percentEncoded: false)
        #expect(throws: ScopedFileAccess.Failure.outsideScope(secret)) { try access.readText(at: secret) }
        #expect(throws: ScopedFileAccess.Failure.outsideScope(secret)) { try access.writeText("x", to: secret) }
        let traversal = path("../outside/secret.txt")
        #expect(throws: ScopedFileAccess.Failure.outsideScope(traversal)) { try access.readText(at: traversal) }
        // A sibling whose name starts with the root's name is still outside.
        let sibling = root.path(percentEncoded: false) + "-sibling/file.txt"
        #expect(throws: ScopedFileAccess.Failure.outsideScope(sibling)) { try access.resolve(sibling) }
    }

    @Test func rejectsSymlinksThatEscape() throws {
        try FileManager.default.createSymbolicLink(at: root.appending(path: "escape"), withDestinationURL: outside)
        let escaped = path("escape/secret.txt")
        #expect(throws: ScopedFileAccess.Failure.outsideScope(escaped)) { try access.readText(at: escaped) }
    }

    @Test func rejectsRelativeMissingAndBinaryFiles() throws {
        #expect(throws: ScopedFileAccess.Failure.notAbsolute("lines.txt")) { try access.readText(at: "lines.txt") }
        #expect(throws: ScopedFileAccess.Failure.notFound(path("missing.txt"))) {
            try access.readText(at: path("missing.txt"))
        }
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: root.appending(path: "binary.bin"))
        #expect(throws: ScopedFileAccess.Failure.notText(path("binary.bin"))) {
            try access.readText(at: path("binary.bin"))
        }
        try FileManager.default.createDirectory(at: root.appending(path: "dir"), withIntermediateDirectories: true)
        #expect(throws: ScopedFileAccess.Failure.notRegularFile(path("dir"))) {
            try access.writeText("x", to: path("dir"))
        }
    }

    @Test func acceptsTheRootItselfAndMultipleRoots() throws {
        #expect(try access.resolve(root.path(percentEncoded: false)).resolvingSymlinksInPath().path == root.path)
        let both = ScopedFileAccess(roots: [root, outside])
        #expect(try both.readText(at: outside.appending(path: "secret.txt").path(percentEncoded: false)) == "secret")
    }

    @Test func followsInternalLinksButRejectsDanglingExternalLinks() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appending(path: "lines.txt"))
        #expect(try access.readText(at: link.path) == "one\ntwo\nthree\nfour")
        try access.writeText("changed", to: link.path)
        #expect(try String(contentsOf: root.appending(path: "lines.txt"), encoding: .utf8) == "changed")
        let escape = root.appending(path: "escape")
        let missing = outside.appending(path: "missing.txt")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: missing)
        #expect(throws: (any Error).self) { try access.writeText("secret", to: escape.path) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test(arguments: [false, true]) func rejectsParentSymlinkSubstitution(write: Bool) throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let parent = root.appending(path: "parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try "inside".write(to: parent.appending(path: "secret.txt"), atomically: true, encoding: .utf8)
        var scoped = access
        scoped.beforeAccess = {
            try? FileManager.default.moveItem(at: parent, to: root.appending(path: "old-parent"))
            try? FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        }
        #expect(throws: (any Error).self) {
            if write {
                try scoped.writeText("overwritten", to: parent.appending(path: "secret.txt").path)
            } else {
                _ = try scoped.readText(at: parent.appending(path: "secret.txt").path)
            }
        }
        #expect(try String(contentsOf: outside.appending(path: "secret.txt"), encoding: .utf8) == "secret")
    }

    @Test func rejectsNULPathsAndHandlesExtremeLineRanges() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(throws: (any Error).self) { try access.readText(at: path("lines.txt") + "\0ignored") }
        #expect(throws: (any Error).self) { try access.writeText("bad", to: path("lines.txt") + "\0ignored") }
        #expect(try access.readText(at: path("lines.txt"), line: 2, limit: Int.max) == "two\nthree\nfour")
        #expect(try access.readText(at: path("lines.txt"), line: Int.min, limit: 1) == "one")
    }

    @Test func atomicReplacementPreservesPermissionsAndDoesNotWriteThroughHardLinks() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let original = outside.appending(path: "secret.txt")
        let linked = root.appending(path: "linked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: original.path)
        try FileManager.default.linkItem(at: original, to: linked)
        try access.writeText("replacement", to: linked.path)
        #expect(try String(contentsOf: original, encoding: .utf8) == "secret")
        #expect(try String(contentsOf: linked, encoding: .utf8) == "replacement")
        #expect(try FileManager.default.attributesOfItem(atPath: linked.path)[.posixPermissions] as? Int == 0o750)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["lines.txt", "linked.txt"])
    }

    @Test func rejectsSpecialFilesWithoutBlockingAndReportsMissingRoots() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let fifo = path("fifo")
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(throws: ScopedFileAccess.Failure.notRegularFile(fifo)) { try access.readText(at: fifo) }
        #expect(throws: ScopedFileAccess.Failure.notRegularFile(fifo)) { try access.writeText("x", to: fifo) }
        #expect(throws: ScopedFileAccess.Failure.notRegularFile(root.path)) { try access.readText(at: root.path) }
        #expect(throws: ScopedFileAccess.Failure.notRegularFile(root.path)) { try access.writeText("x", to: root.path) }
        let missing = ScopedFileAccess(roots: [root.appending(path: "missing")])
        #expect(throws: (any Error).self) { try missing.writeText("x", to: path("missing/file")) }
        #expect(throws: (any Error).self) { try access.writeText("x", to: path("lines.txt/file")) }
    }

    @Test func supportsExplicitFilesystemRootAndOverlappingRoots() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let all = ScopedFileAccess(roots: [URL(filePath: "/")])
        #expect(try all.readText(at: path("lines.txt"), limit: 1) == "one")
        let nested = root.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let overlapping = ScopedFileAccess(roots: [root, nested])
        try overlapping.writeText("nested", to: nested.appending(path: "file").path)
        #expect(try all.readText(at: nested.appending(path: "file").path) == "nested")
    }

    @Test(arguments: [false, true]) func rejectsFinalSymlinkSubstitution(write: Bool) throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appending(path: "lines.txt")
        let secret = outside.appending(path: "secret.txt")
        var scoped = access
        scoped.beforeAccess = {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        }
        #expect(throws: (any Error).self) {
            if write { try scoped.writeText("bad", to: file.path) } else { _ = try scoped.readText(at: file.path) }
        }
        #expect(try String(contentsOf: secret, encoding: .utf8) == "secret")
    }
}
