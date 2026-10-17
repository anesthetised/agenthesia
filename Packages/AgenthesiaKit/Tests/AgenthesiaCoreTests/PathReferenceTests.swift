import Foundation
import Testing
import Workspace

@testable import AgenthesiaCore

@Suite struct PathReferenceTests {
    @Test func parsesLineAndColumnSuffixes() {
        #expect(PathReference("Sources/App.swift") == PathReference(path: "Sources/App.swift"))
        #expect(PathReference("Sources/App.swift:12") == PathReference(path: "Sources/App.swift", line: 12))
        #expect(
            PathReference("Sources/App.swift:12:3") == PathReference(path: "Sources/App.swift", line: 12, column: 3)
        )
        #expect(PathReference("Sources/App.swift#L12") == PathReference(path: "Sources/App.swift", line: 12))
        #expect(PathReference("/tmp/a.txt:7") == PathReference(path: "/tmp/a.txt", line: 7))
    }

    @Test func findsIndexedPathsWithoutTheFileSystem() {
        let paths: Set = ["Sources/App.swift", "README.md"]
        let roots = ["/private/tmp/session", "/tmp/session/"]
        #expect(PathReference(path: "Sources/App.swift").indexedPath(in: paths, roots: roots) == "Sources/App.swift")
        #expect(PathReference(path: "/tmp/session/README.md").indexedPath(in: paths, roots: roots) == "README.md")
        #expect(
            PathReference(path: "/private/tmp/session/Sources/App.swift").indexedPath(in: paths, roots: roots)
                == "Sources/App.swift"
        )
        #expect(PathReference(path: "Missing.swift").indexedPath(in: paths, roots: roots) == nil)
        #expect(PathReference(path: "/tmp/sessionREADME.md").indexedPath(in: paths, roots: roots) == nil)
        #expect(PathReference(path: "/elsewhere/README.md").indexedPath(in: paths, roots: roots) == nil)
        #expect(PathReference(path: "/tmp/session").indexedPath(in: paths, roots: roots) == nil)
    }

    @Test func dropsLeadingDotSlash() {
        #expect(PathReference("./Sources/App.swift:4") == PathReference(path: "Sources/App.swift", line: 4))
        #expect(PathReference("././a/b") == PathReference(path: "./a/b"))
    }

    @Test func requiresSlashOrExtension() {
        #expect(PathReference("README.md") != nil)
        #expect(PathReference("docs/Makefile") != nil)
        #expect(PathReference("Makefile") == nil)
        #expect(PathReference("swift") == nil)
        #expect(PathReference("version.") == nil)
        #expect(PathReference(".env") == nil)
    }

    @Test func rejectsWhitespaceEmptyAndUnsupportedShapes() {
        #expect(PathReference("") == nil)
        #expect(PathReference("a b/c.swift") == nil)
        #expect(PathReference("a/b.swift\n") == nil)
        #expect(PathReference("./") == nil)
        #expect(PathReference("a/b\0c") == nil)
        #expect(PathReference("https://example.com/a.html") == nil)
        #expect(PathReference(":12") == nil)
        #expect(PathReference("#L3") == nil)
    }

    @Test func keepsNonNumericSuffixesInThePath() {
        #expect(PathReference("a/b.swift:x") == PathReference(path: "a/b.swift:x"))
        #expect(PathReference("a/b.swift:0") == PathReference(path: "a/b.swift", line: 0))
    }

    // MARK: Resolution

    private func makeRoot() throws -> (root: URL, base: URL) {
        let base = ScopedFileAccess(roots: [FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)])
            .roots[0]
        let root = base.appending(path: "workspace")
        try FileManager.default.createDirectory(
            at: root.appending(path: "Sources"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: base.appending(path: "outside"),
            withIntermediateDirectories: true
        )
        return (root, base)
    }

    @Test func resolvesRelativeAndAbsolutePathsInsideTheRoot() throws {
        let (root, base) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let relative = PathReference(path: "Sources/App.swift", line: 3)
        #expect(relative.relativePath(in: root) == "Sources/App.swift")
        let absolute = PathReference(path: root.path(percentEncoded: false) + "/Sources/App.swift")
        #expect(absolute.relativePath(in: root) == "Sources/App.swift")
        // A file that no longer exists still resolves.
        #expect(PathReference(path: "gone/missing.swift").relativePath(in: root) == "gone/missing.swift")
    }

    @Test func resolvesAliasedAbsolutePaths() throws {
        let (root, base) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let alias = "/var" + root.path(percentEncoded: false).dropFirst("/private/var".count) + "/Sources/App.swift"
        try #require(root.path(percentEncoded: false).hasPrefix("/private/var"))
        #expect(PathReference(path: alias).relativePath(in: root) == "Sources/App.swift")
    }

    @Test func rejectsPathsOutsideTheRoot() throws {
        let (root, base) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appending(path: "outside/secret.txt").path(percentEncoded: false)
        #expect(PathReference(path: outside).relativePath(in: root) == nil)
        #expect(PathReference(path: "/etc/hosts").relativePath(in: root) == nil)
        // A sibling that merely shares the root's name as a prefix.
        #expect(PathReference(path: root.path(percentEncoded: false) + "-other/a.txt").relativePath(in: root) == nil)
        #expect(PathReference(path: "../outside/secret.txt").relativePath(in: root) == nil)
        #expect(PathReference(path: "Sources/../../outside/a.txt").relativePath(in: root) == nil)
        #expect(PathReference(path: "Sources/../Sources/a.txt").relativePath(in: root) == nil)
        #expect(PathReference(path: root.path(percentEncoded: false)).relativePath(in: root) == nil)
    }

    @Test func rejectsSymlinkedEscapes() throws {
        let (root, base) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("x".utf8).write(to: base.appending(path: "outside/secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "link"),
            withDestinationURL: base.appending(path: "outside")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "file.txt"),
            withDestinationURL: base.appending(path: "outside/secret.txt")
        )
        #expect(PathReference(path: "link/secret.txt").relativePath(in: root) == nil)
        #expect(PathReference(path: "file.txt").relativePath(in: root) == nil)
        #expect(
            PathReference(path: root.path(percentEncoded: false) + "/link/secret.txt").relativePath(in: root) == nil
        )
    }
}
