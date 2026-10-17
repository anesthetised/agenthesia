import ACP
import AppKit
import Foundation
import Rendering
import Testing

@testable import AgenthesiaUI

@MainActor
@Suite struct TranscriptPathLinksTests {
    @Test func urlRoundTripsUnusualPaths() throws {
        for path in ["a.swift", "dir/some file #1?.swift", "é/👩.swift", "a%20b/c:d.swift"] {
            for line in [nil, 7] {
                let link = PathLink(path: path, line: line)
                let url = try #require(link.url)
                #expect(url.scheme == "agenthesia-path")
                #expect(url.query == (line.map { "line=\($0)" }))
                #expect(url.fragment == nil)
                #expect(PathLink(url) == link)
            }
        }
    }

    @Test func rejectsForeignAndEmptyLinks() throws {
        #expect(PathLink(try #require(URL(string: "https://example.com/a.swift"))) == nil)
        #expect(PathLink(try #require(URL(string: "agenthesia-path://open/"))) == nil)
        #expect(PathLink(try #require(URL(string: "agenthesia-path://open/a.swift?line=x")))?.line == nil)
        #expect(PathLink.claims(try #require(URL(string: "agenthesia-path://open/"))))
        #expect(!PathLink.claims(try #require(URL(string: "https://example.com"))))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "links-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func targetsResolveLocationsAndDiffsInsideTheRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let absolute = root.appending(path: "Sources/A.swift").path(percentEncoded: false)
        let tool = ACP.ToolCall(
            toolCallId: "t",
            title: "Edit",
            content: [
                .diff(ACP.Diff(path: "B.swift", oldText: nil, newText: "x")),
                .diff(ACP.Diff(path: "/etc/hosts", oldText: nil, newText: "x")),
            ],
            locations: [
                ACP.ToolCallLocation(path: absolute, line: 4), ACP.ToolCallLocation(path: "../up.swift", line: 1),
            ]
        )
        let targets = PathLink.targets(of: tool, root: root)
        #expect(targets.map(\.display) == [absolute + ":4", "B.swift"])
        #expect(targets.map(\.link) == [PathLink(path: "Sources/A.swift", line: 4), PathLink(path: "B.swift")])
    }

    private func inlineCode(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.backgroundColor: NSColor.gray])
    }

    @Test func applyLinksInlineCodeInOrderAndSkipsPlainText() throws {
        let text = NSMutableAttributedString(string: "Edit a.swift:3 then ")
        text.append(inlineCode("a.swift:3"))
        text.append(NSAttributedString(string: " and "))
        text.append(inlineCode("b.swift"))
        let targets = [
            ("a.swift:3", PathLink(path: "a.swift", line: 3)), ("b.swift", PathLink(path: "b.swift")),
            ("missing.swift", PathLink(path: "missing.swift")),
        ]
        PathLink.apply(targets, to: text)
        var links: [(String, URL)] = []
        text.enumerateAttribute(.link, in: NSRange(0..<text.length)) { value, range, _ in
            if let url = value as? URL { links.append((text.attributedSubstring(from: range).string, url)) }
        }
        #expect(links.map(\.0) == ["a.swift:3", "b.swift"])
        #expect(links.compactMap { PathLink($0.1) } == [PathLink(path: "a.swift", line: 3), PathLink(path: "b.swift")])
        // The plain mention at the start is not linked.
        #expect(text.attribute(.link, at: 5, effectiveRange: nil) == nil)
    }

    @Test func toolRowsLinkLocationsAndDiffPaths() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LiveTranscriptSource()
        source.root = root
        let tool = ACP.ToolCall(
            toolCallId: "t",
            title: "Edit a.swift",
            content: [.diff(ACP.Diff(path: "b.swift", oldText: "x", newText: "y"))],
            locations: [ACP.ToolCallLocation(path: "a.swift", line: 2)]
        )
        let card = LiveTranscriptSource.toolCard(tool, expanded: false)
        let message = source.render(
            id: 1,
            role: "Tool",
            markdown: card.markdown,
            links: PathLink.targets(of: tool, root: root)
        )
        var linked: [String] = []
        message.text.enumerateAttribute(.link, in: NSRange(0..<message.text.length)) { value, range, _ in
            if value != nil { linked.append(message.text.attributedSubstring(from: range).string) }
        }
        #expect(linked == ["a.swift:2", "b.swift"])
        // Copying keeps the Markdown the agent's data produced, without private links.
        #expect(!message.markdown.contains("agenthesia-path"))
        // A cached row keeps its links.
        let again = source.render(id: 1, role: "Tool", markdown: card.markdown)
        #expect(again.text === message.text)
    }
}
