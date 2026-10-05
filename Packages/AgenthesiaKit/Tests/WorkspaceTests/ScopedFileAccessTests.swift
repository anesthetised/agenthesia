import Foundation
import Testing
import Workspace

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
        #expect(throws: ScopedFileAccess.Failure.notFound(path("dir"))) { try access.writeText("x", to: path("dir")) }
    }

    @Test func acceptsTheRootItselfAndMultipleRoots() throws {
        #expect(try access.resolve(root.path(percentEncoded: false)).path() == root.path())
        let both = ScopedFileAccess(roots: [root, outside])
        #expect(try both.readText(at: outside.appending(path: "secret.txt").path(percentEncoded: false)) == "secret")
    }
}
