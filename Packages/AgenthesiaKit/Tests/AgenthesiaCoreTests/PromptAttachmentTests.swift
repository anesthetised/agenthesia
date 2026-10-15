import ACP
import Foundation
import Testing

@testable import AgenthesiaCore

@Suite struct PromptAttachmentTests {
    @Test func linksMapCheckoutFilesToTheWorktreeCopy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "attachment-test-\(UUID())")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = root.appending(path: "repo"), worktree = root.appending(path: "trees/repo/id")
        let sibling = root.appending(path: "repo-other")
        for directory in [checkout.appending(path: "src"), worktree.appending(path: "src"), sibling] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for file in [
            checkout.appending(path: "src/main.swift"), worktree.appending(path: "src/main.swift"),
            checkout.appending(path: "untracked.txt"), sibling.appending(path: "notes.md"),
        ] {
            try "print(1)".write(to: file, atomically: true, encoding: .utf8)
        }
        let pair = (checkout: checkout, worktree: worktree)

        let mapped = ACP.ResourceLink.file(checkout.appending(path: "src/main.swift"), checkout: pair)
        #expect(mapped.uri == worktree.appending(path: "src/main.swift").absoluteString)
        #expect(mapped.name == "main.swift")
        #expect(mapped.size == 8)

        // Untracked files are not in the worktree; files of a sibling with the same prefix are not in the checkout.
        let untracked = checkout.appending(path: "untracked.txt")
        #expect(ACP.ResourceLink.file(untracked, checkout: pair).uri == untracked.absoluteString)
        #expect(ACP.ResourceLink.file(untracked).mimeType == "text/plain")
        let notes = sibling.appending(path: "notes.md")
        #expect(ACP.ResourceLink.file(notes, checkout: pair).uri == notes.absoluteString)
        #expect(ACP.ResourceLink.file(notes).name == "notes.md")

        let directory = ACP.ResourceLink.file(checkout.appending(path: "src"), checkout: pair)
        #expect(directory.uri.hasPrefix(worktree.appending(path: "src").absoluteString))
        #expect(directory.name == "src")
        #expect(directory.size == nil && directory.mimeType == nil)
        #expect(ACP.ResourceLink.file(checkout, checkout: pair).name == "id")
    }

    @Test @MainActor func promptPutsTextBeforeAttachments() {
        let file = URL(filePath: "/nonexistent/a.txt")
        let blocks = LiveSession.content("Look", attachments: [file], checkout: nil)
        #expect(blocks.count == 2)
        guard case .text(let text) = blocks[0], case .resourceLink(let link) = blocks[1] else {
            Issue.record("Unexpected blocks \(blocks)")
            return
        }
        #expect(text.text == "Look")
        #expect(link.uri == "file:///nonexistent/a.txt" && link.size == nil)
        #expect(LiveSession.content(" \n", attachments: [file], checkout: nil).count == 1)
        #expect(LiveSession.content("Hi", attachments: [], checkout: nil) == [.init(text: "Hi")])
    }
}
