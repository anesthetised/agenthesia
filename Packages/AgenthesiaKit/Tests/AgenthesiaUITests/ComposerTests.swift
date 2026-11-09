import ACP
import AppKit
import Testing

@testable import AgenthesiaUI

@Suite @MainActor
struct ComposerTests {
    let commands: [ACP.AvailableCommand] = [
        .init(name: "web", description: "Search the web", input: .init(hint: "query")),
        .init(name: "Compact", description: "Summarize"),
        .init(name: "commit", description: "Commit changes"),
    ]

    @Test func commandsMatchABareSlashWordByPrefix() {
        #expect(ComposerInput.commandMatches("/", in: commands).count == 3)
        #expect(ComposerInput.commandMatches("/co", in: commands).map(\.name) == ["Compact", "commit"])
        #expect(ComposerInput.commandMatches("/W", in: commands).map(\.name) == ["web"])
        #expect(ComposerInput.commandMatches("/web ", in: commands).isEmpty)
        #expect(ComposerInput.commandMatches("web", in: commands).isEmpty)
        #expect(ComposerInput.commandMatches("/x", in: commands).isEmpty)
        #expect(ComposerInput.commandMatches("", in: []).isEmpty)
    }

    @Test func keysNavigateCommandsBeforeEditing() {
        let up = #selector(NSResponder.moveUp(_:)), down = #selector(NSResponder.moveDown(_:))
        let tab = #selector(NSResponder.insertTab(_:)), enter = #selector(NSResponder.insertNewline(_:))
        let escape = #selector(NSResponder.cancelOperation(_:))
        #expect(ComposerInput.keyAction(down, matches: 3, selection: 0, lineBreak: false) == .select(1))
        #expect(ComposerInput.keyAction(down, matches: 3, selection: 2, lineBreak: false) == .select(2))
        #expect(ComposerInput.keyAction(up, matches: 3, selection: 0, lineBreak: false) == .select(0))
        #expect(ComposerInput.keyAction(tab, matches: 3, selection: 1, lineBreak: false) == .complete(1))
        #expect(ComposerInput.keyAction(enter, matches: 2, selection: 5, lineBreak: true) == nil)
        #expect(ComposerInput.keyAction(escape, matches: 3, selection: 0, lineBreak: false) == .dismiss)
        // Without listed commands, arrows and Tab edit text and Return sends unless it is a line break.
        #expect(ComposerInput.keyAction(up, matches: 0, selection: 0, lineBreak: false) == nil)
        #expect(ComposerInput.keyAction(tab, matches: 0, selection: 0, lineBreak: false) == nil)
        #expect(ComposerInput.keyAction(enter, matches: 0, selection: 0, lineBreak: false) == .submit)
        #expect(ComposerInput.keyAction(enter, matches: 0, selection: 0, lineBreak: true) == nil)
        #expect(ComposerInput.keyAction(escape, matches: 0, selection: 0, lineBreak: false) == .dismiss)
    }

    @Test func queueShortcutsTakePrecedenceOverCommandCompletion() {
        let enter = #selector(NSResponder.insertNewline(_:))
        let escape = #selector(NSResponder.cancelOperation(_:))
        let up = #selector(NSResponder.moveUp(_:))
        #expect(ComposerInput.keyAction(enter, matches: 2, selection: 0, lineBreak: false, command: true) == .sendNow)
        #expect(
            ComposerInput.keyAction(enter, matches: 2, selection: 0, lineBreak: true, command: true, shift: true)
                == .sendAllNow
        )
        #expect(ComposerInput.keyAction(escape, matches: 0, selection: 0, lineBreak: false, command: true) == .stop)
        #expect(ComposerInput.keyAction(up, matches: 0, selection: 0, lineBreak: false, empty: true) == .recall)
        #expect(ComposerInput.keyAction(up, matches: 0, selection: 0, lineBreak: false, empty: false) == nil)
    }

    @Test func attachmentsAreFileURLsWithoutDuplicates() {
        var attachments: [URL] = []
        let file = URL(filePath: "/tmp/a.txt")
        ComposerInput.add([file, URL(string: "https://example.com")!, file], to: &attachments)
        ComposerInput.add([file, URL(filePath: "/tmp/b")], to: &attachments)
        #expect(attachments == [file, URL(filePath: "/tmp/b")])
    }

    @Test func heightGrowsWithLinesWithinBounds() {
        let line = NSLayoutManager().defaultLineHeight(for: ComposerTextView.font)
        let empty = ComposerTextView.height(of: "", width: 400)
        #expect(empty == ceil(line * 2))
        #expect(ComposerTextView.height(of: "a\nb\nc", width: 400) > empty)
        #expect(ComposerTextView.height(of: "a\nb\n", width: 400) > ComposerTextView.height(of: "a\nb", width: 400))
        #expect(ComposerTextView.height(of: String(repeating: "line\n", count: 50), width: 400) == ceil(line * 6))
    }

    @Test func pastedFilesBecomeAttachmentsAndTextIsInserted() throws {
        let view = FileTextView(usingTextLayoutManager: true)
        var received: [URL] = []
        view.onFiles = { received += $0 }
        let pasteboard = NSPasteboard(name: .init("composer-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([NSString(string: "plain")])
        #expect(!view.takeFiles(from: pasteboard))
        pasteboard.clearContents()
        let file = URL(filePath: "/tmp/composer.txt")
        pasteboard.writeObjects([file as NSURL])
        #expect(view.takeFiles(from: pasteboard))
        #expect(received == [file])
    }

    @Test func anInsertionGoesAtTheCaretOnLinesOfItsOwn() {
        #expect(FileTextView.block("q", after: "") == "q\n")
        #expect(FileTextView.block("q", after: "line\n") == "q\n")
        #expect(FileTextView.block("q", after: "Hi") == "\nq\n")
        let view = FileTextView()
        view.string = "Hi there"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.insertBlock("quote")
        #expect(view.string == "Hi\nquote\n there")
        #expect(view.selectedRange() == NSRange(location: 9, length: 0))
        // Selected text stays; the quote follows it.
        view.string = "Hi there"
        view.setSelectedRange(NSRange(location: 0, length: 2))
        view.insertBlock("quote")
        #expect(view.string == "Hi\nquote\n there")
    }

    @Test func textViewReportsEditsAndCommands() throws {
        var text = "", commands: [Selector] = []
        let representable = ComposerTextView(
            text: .init(get: { text }, set: { text = $0 }),
            isEditable: true,
            onCommand: {
                commands.append($0); return true
            },
            onFiles: { _ in }
        )
        let coordinator = representable.makeCoordinator()
        let view = NSTextView()
        view.string = "/web"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        #expect(text == "/web")
        #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(commands == [#selector(NSResponder.insertTab(_:))])
    }

    /// While a form is docked, Return answers, Escape declines, ↑ ↓ move the pick in an empty composer, ⌘. stops and
    /// ⌘Return sends nothing (#326).
    @Test func aDockedFormTakesTheComposerKeys() {
        let enter = #selector(NSResponder.insertNewline(_:))
        let escape = #selector(NSResponder.cancelOperation(_:))
        let up = #selector(NSResponder.moveUp(_:))
        let down = #selector(NSResponder.moveDown(_:))
        func key(
            _ selector: Selector,
            lineBreak: Bool = false,
            command: Bool = false,
            empty: Bool = true
        )
            -> ComposerInput.KeyAction?
        {
            ComposerInput.keyAction(
                selector,
                matches: 0,
                selection: 0,
                lineBreak: lineBreak,
                command: command,
                empty: empty,
                answering: true
            )
        }
        #expect(key(enter) == .submit && key(enter, empty: false) == .submit)
        #expect(key(enter, lineBreak: true) == nil)
        #expect(key(enter, command: true) == .ignore)
        #expect(key(escape) == .decline && key(escape, command: true) == .stop)
        #expect(key(up) == .movePick(-1) && key(down) == .movePick(1))
        #expect(key(up, empty: false) == nil && key(down, empty: false) == nil)
        // Without a form, ↑ in an empty composer still recalls the last queued message.
        #expect(ComposerInput.keyAction(up, matches: 0, selection: 0, lineBreak: false, empty: true) == .recall)
    }

    @Test func digitsPickChoicesOnlyInAnEmptyComposer() {
        #expect(ComposerInput.choiceIndex("1", modifiers: [], empty: true, choices: 3) == 0)
        #expect(ComposerInput.choiceIndex("3", modifiers: [.shift], empty: true, choices: 3) == 2)
        #expect(ComposerInput.choiceIndex("4", modifiers: [], empty: true, choices: 3) == nil)
        #expect(ComposerInput.choiceIndex("0", modifiers: [], empty: true, choices: 9) == nil)
        #expect(ComposerInput.choiceIndex("1", modifiers: [], empty: false, choices: 3) == nil)
        #expect(ComposerInput.choiceIndex("1", modifiers: [.command], empty: true, choices: 3) == nil)
        #expect(ComposerInput.choiceIndex("1", modifiers: [.option], empty: true, choices: 3) == nil)
        #expect(ComposerInput.choiceIndex("12", modifiers: [], empty: true, choices: 9) == nil)
        #expect(ComposerInput.choiceIndex(nil, modifiers: [], empty: true, choices: 3) == nil)
    }
}
