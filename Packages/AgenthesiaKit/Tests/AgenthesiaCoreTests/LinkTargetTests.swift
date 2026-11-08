import Foundation
import Testing
import Workspace

@testable import AgenthesiaCore

@Suite struct LinkTargetTests {
    private func makeRoot() throws -> (root: URL, base: URL) {
        let base = ScopedFileAccess(roots: [FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)])
            .roots[0]
        let root = base.appending(path: "workspace")
        try FileManager.default.createDirectory(at: root.appending(path: "docs/adr"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appending(path: "outside"), withIntermediateDirectories: true)
        return (root, base)
    }

    private func target(_ link: String, in directory: String = "docs", root: URL) throws -> LinkTarget {
        LinkTarget(
            try #require(URL(string: link)),
            base: root.appending(path: directory, directoryHint: .isDirectory),
            root: root
        )
    }

    @Test func relativeLinksResolveAgainstTheBaseDirectory() throws {
        let (root, base) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try target("adr/0010-prompt-queue.md", root: root) == .file("docs/adr/0010-prompt-queue.md"))
        #expect(try target("./PLAN.md", root: root) == .file("docs/PLAN.md"))
        #expect(try target("/README.md", in: "docs", root: root) == .ignored)
        #expect(try target("a%20b.md", root: root) == .file("docs/a b.md"))
    }

    @Test func parentComponentsAreStandardized() throws {
        let (root, base) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try target("../README.md", root: root) == .file("README.md"))
        #expect(try target("adr/../../Sources/App.swift", root: root) == .file("Sources/App.swift"))
        #expect(try target("../../outside/secret.md", root: root) == .ignored)
        #expect(try target("../..", root: root) == .ignored)
    }

    @Test func linksOutsideTheRootAreIgnored() throws {
        let (root, base) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try target("../../outside/a.md", root: root) == .ignored)
        #expect(try target("/etc/hosts", root: root) == .ignored)
        let link = root.appending(path: "escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base.appending(path: "outside"))
        #expect(try target("../escape/a.md", root: root) == .ignored)
    }

    @Test func absoluteFileURLsInsideTheRootOpen() throws {
        let (root, base) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let inside = root.appending(path: "Sources/App.swift")
        #expect(LinkTarget(inside, base: root, root: root) == .file("Sources/App.swift"))
        #expect(
            LinkTarget(base.appending(path: "outside/a.md"), base: root, root: root) == .ignored
        )
    }

    @Test func fragmentsAndQueriesAreDropped() throws {
        let (root, base) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try target("adr/0010.md#decision", root: root) == .file("docs/adr/0010.md"))
        #expect(try target("PLAN.md?plain=1", root: root) == .file("docs/PLAN.md"))
        #expect(try target("#decision", root: root) == .ignored)
    }

    @Test func webAndMailLinksAreExternal() throws {
        let (root, base) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        for link in [
            "http://example.com/a", "https://example.com/a#b", "mailto:owner@example.com", "HTTPS://example.com",
        ] {
            let url = try #require(URL(string: link))
            #expect(try target(link, root: root) == .external(url))
        }
    }

    @Test func otherSchemesAreIgnored() throws {
        let (root, base) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        for link in [
            "ftp://example.com/a", "javascript:alert(1)", "x-apple.systempreferences:", "tel:123",
            "agenthesia-path://open/a.swift",
        ] {
            #expect(try target(link, root: root) == .ignored)
        }
    }
}
