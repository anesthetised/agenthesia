import AppKit
import Observation
import SwiftUI
import Testing

@testable import AgenthesiaUI

@Suite @MainActor
struct DemoSessionTests {
    @Test func shiftReturnInsertsAtTheNativeSelection() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.string = "Hello 🌍 world"
        editor.setSelectedRange(NSRange(location: 6, length: 2))
        #expect(RootView.handleComposerReturn(modifiers: .shift, responder: editor) == .handled)
        #expect(editor.string == "Hello \n world")
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
        #expect(RootView.handleComposerReturn(modifiers: .shift, responder: editor) == .handled)
        #expect(editor.string == "Hello \n\n world")
        #expect(RootView.handleComposerReturn(modifiers: [], responder: editor) == .ignored)
        #expect(RootView.handleComposerReturn(modifiers: .command, responder: editor) == .ignored)
        #expect(RootView.handleComposerReturn(modifiers: [.command, .shift], responder: editor) == .ignored)
        #expect(RootView.handleComposerReturn(modifiers: .shift, responder: NSResponder()) == .ignored)
        #expect(editor.string == "Hello \n\n world")
    }

    @Test func blankAndBusyPromptsAreRejected() throws {
        let session = DemoSession()
        #expect(session.begin(" \n ") == nil)
        #expect(session.messages.count == 2)
        let token = try #require(session.begin("  Hello  "))
        #expect(session.messages[2].markdown == "Hello")
        #expect(session.begin("Busy") == nil)
        session.finish(token)
        #expect(!session.isStreaming)
    }

    @Test func responseIsDeterministicAndRendered() throws {
        let session = DemoSession()
        let token = try #require(session.begin("Hello"))
        for chunk in DemoSession.responseChunks { session.receive(chunk, for: token) }
        session.finish(token)
        #expect(session.messages.last?.markdown == DemoSession.responseChunks.joined())
        #expect(session.messages.last?.text.string.contains("Hello from Agenthesia") == true)
        #expect(session.messages.last?.text.string.contains("```") == false)
        #expect(!session.isStreaming)
    }

    @Test func stopKeepsPartialTextAndRejectsStaleChunksAndCompletion() throws {
        let session = DemoSession()
        let oldTurn = try #require(session.begin("First"))
        session.receive("Partial answer", for: oldTurn)
        session.stop()
        #expect(session.messages.last?.markdown == "Partial answer\n\n*Demo response stopped.*")
        let newTurn = try #require(session.begin("Second"))
        session.receive("stale", for: oldTurn)
        session.finish(oldTurn)
        #expect(session.turn == newTurn)
        #expect(session.messages.last?.markdown == "")
        session.receive("fresh", for: newTurn)
        #expect(session.messages.last?.text.string == "fresh")
        session.stop()
    }

    @Test func tableCopiesSelectedMessagesInTranscriptOrder() {
        let session = DemoSession()
        let controller = DemoTranscriptController()
        controller.update(session)
        controller.table.selectRowIndexes([0, 1], byExtendingSelection: false)
        #expect(controller.selectedMarkdown == session.messages.map(\.markdown).joined(separator: "\n\n"))
        controller.table.deselectAll(nil)
        #expect(controller.selectedMarkdown.isEmpty)
    }

    @Test func coalescedChunksAndCompletionKeepSelectedText() throws {
        let session = DemoSession()
        let token = try #require(session.begin("Hello"))
        session.receive("First paragraph.", for: token)
        let controller = DemoTranscriptController()
        let window = host(controller)
        defer { window.close() }
        controller.update(session)
        let row = try #require(controller.table.view(atColumn: 0, row: 3, makeIfNecessary: true))
        let text = try #require(textView(in: row))
        #expect(text.textLayoutManager != nil)
        #expect(text.isSelectable && !text.isEditable)
        text.setSelectedRange(NSRange(location: 0, length: 5))
        session.receive("\n\nSecond ", for: token)
        session.receive("paragraph.", for: token)
        controller.update(session)
        #expect(text.string == session.messages[3].text.string)
        #expect(text.selectedRange() == NSRange(location: 0, length: 5))
        session.receive("\n\nFinal paragraph.", for: token)
        session.finish(token)
        controller.update(session)
        #expect(text.string == session.messages[3].text.string)
        #expect(text.selectedRange() == NSRange(location: 0, length: 5))
        #expect(textView(in: try #require(controller.table.view(atColumn: 0, row: 3, makeIfNecessary: true))) === text)
    }

    @Test func streamingPreservesReaderScrollAndFollowsTheBottom() async throws {
        let session = DemoSession()
        let token = try #require(session.begin("Hello"))
        session.receive(String(repeating: "A paragraph to read.\n\n", count: 30), for: token)
        let controller = DemoTranscriptController()
        let window = host(controller)
        defer { window.close() }
        controller.update(session)
        _ = controller.table.view(atColumn: 0, row: 3, makeIfNecessary: true)
        controller.table.noteHeightOfRows(withIndexesChanged: [3])
        controller.table.layoutSubtreeIfNeeded()
        #expect(controller.table.frame.height > 500)
        controller.scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: controller.scroll)
        let origin = controller.scroll.contentView.bounds.origin
        session.receive("Another paragraph.\n\n", for: token)
        controller.update(session)
        await nextMainTurn()
        #expect(abs(controller.scroll.contentView.bounds.origin.y - origin.y) < 1)
        let bottom = max(0, controller.table.frame.height - controller.scroll.contentView.bounds.height)
        controller.scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: controller.scroll)
        session.receive("Last paragraph.\n\n", for: token)
        controller.update(session)
        await nextMainTurn()
        #expect(abs(controller.scroll.contentView.bounds.maxY - controller.table.frame.height) < 1)
        session.stop()
    }

    @Test func initiallyFittingTranscriptKeepsFollowingDeferredRowGrowth() async throws {
        let session = DemoSession()
        let controller = DemoTranscriptController()
        let window = host(controller)
        defer { window.close() }
        controller.scroll.frame.size.height = 700
        controller.update(session)
        #expect(controller.scroll.contentView.bounds.origin.y == 0)
        let token = try #require(session.begin("Hello"))
        controller.update(session)
        for chunk in DemoSession.responseChunks {
            session.receive(chunk, for: token)
            controller.update(session)
        }
        session.receive(String(repeating: "\n\nA longer streamed paragraph.", count: 30), for: token)
        controller.update(session)
        // Force the late auto-height work that a visible AppKit table performs after updates.
        _ = controller.table.view(atColumn: 0, row: 3, makeIfNecessary: true)
        controller.table.noteHeightOfRows(withIndexesChanged: [3])
        controller.table.layoutSubtreeIfNeeded()
        session.finish(token)
        controller.update(session)
        _ = controller.table.view(atColumn: 0, row: 3, makeIfNecessary: true)
        controller.table.noteHeightOfRows(withIndexesChanged: [3])
        controller.table.layoutSubtreeIfNeeded()
        let end = max(0, controller.table.frame.height - controller.scroll.contentView.bounds.height)
        #expect(end > 0)
        #expect(abs(controller.scroll.contentView.bounds.origin.y - end) < 1)
        // A further deferred height change must not discard follow intent.
        controller.table.setFrameSize(NSSize(width: 600, height: controller.table.frame.height + 80))
        await nextMainTurn()
        #expect(abs(controller.scroll.contentView.bounds.maxY - controller.table.frame.height) < 1)
    }

    @Test func sendTaskStreamsAndStopCancelsFurtherDelivery() async throws {
        let session = DemoSession()
        session.send("Hello")
        #expect(session.isStreaming)
        for _ in 0..<100 where session.messages.last?.markdown.isEmpty == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.messages.last?.markdown.isEmpty == false)
        session.stop()
        let stopped = session.messages.last?.markdown
        #expect(stopped?.contains("Demo response stopped.") == true)
        try await Task.sleep(for: .milliseconds(120))
        #expect(session.messages.last?.markdown == stopped)
        #expect(!session.isStreaming)
    }

    @Test func finishedLongProseWrapsWithinANarrowTable() throws {
        let session = DemoSession()
        let token = try #require(session.begin("Hello"))
        session.receive(DemoSession.responseChunks.joined(), for: token)
        session.finish(token)
        let controller = DemoTranscriptController()
        let window = host(controller)
        defer { window.close() }
        controller.scroll.frame.size.width = 400
        controller.table.frame.size.width = 400
        controller.update(session)
        let row = try #require(controller.table.view(atColumn: 0, row: 3, makeIfNecessary: true))
        row.layoutSubtreeIfNeeded()
        controller.table.noteHeightOfRows(withIndexesChanged: [3])
        controller.table.layoutSubtreeIfNeeded()
        let unlaidRow = try #require(
            controller.tableView(controller.table, viewFor: controller.table.tableColumns[0], row: 3)
        )
        #expect(unlaidRow.fittingSize.width <= 400)
        #expect(unlaidRow.fittingSize.height > 60)
        let field = try #require(messageField(in: row))
        let prose = (field.attributedStringValue.string as NSString).range(of: "Your prompt is shown above.")
        let style =
            field.attributedStringValue.attribute(.paragraphStyle, at: prose.location, effectiveRange: nil)
            as? NSParagraphStyle
        #expect(style?.lineBreakMode == .byWordWrapping)
        #expect(field.lineBreakMode == .byWordWrapping)
        #expect(field.isSelectable)
        #expect(field.alignmentRect(forFrame: field.frame).width <= 352)
        #expect(field.frame.height > 60)
        #expect(field.attributedStringValue.string == session.messages[3].text.string)
    }

    private func messageField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isSelectable { return field }
        return view.subviews.lazy.compactMap { messageField(in: $0) }.first
    }

    @Test func deferredHeightChangesScrollOnlyAfterAppKitReturns() async throws {
        let session = DemoSession()
        let token = try #require(session.begin("Hello"))
        session.receive(String(repeating: "A paragraph to read.\n\n", count: 30), for: token)
        let controller = DemoTranscriptController()
        let window = host(controller)
        defer { window.close() }
        controller.update(session)
        _ = controller.table.view(atColumn: 0, row: 3, makeIfNecessary: true)
        controller.table.noteHeightOfRows(withIndexesChanged: [3])
        controller.table.layoutSubtreeIfNeeded()
        await nextMainTurn()
        let origin = controller.scroll.contentView.bounds.origin
        controller.table.setFrameSize(NSSize(width: 600, height: controller.table.frame.height + 80))
        #expect(controller.scroll.contentView.bounds.origin == origin)
        await nextMainTurn()
        #expect(abs(controller.scroll.contentView.bounds.maxY - controller.table.frame.height) < 1)
        session.stop()
    }

    @Test(arguments: [false, true])
    func sidebarWidthChangesKeepRowsAttachedAndReadable(completed: Bool) async throws {
        let session = DemoSession()
        let token = try #require(session.begin("Hello"))
        for chunk in DemoSession.responseChunks { session.receive(chunk, for: token) }
        if completed { session.finish(token) }
        let controller = DemoTranscriptController()
        let window = host(controller)
        defer { window.close() }
        controller.update(session)
        for width in [600.0, 840.0, 600.0, 840.0, 400.0, 840.0, 600.0] {
            window.setContentSize(NSSize(width: width, height: 300))
            controller.scroll.layoutSubtreeIfNeeded()
            for rowIndex in session.messages.indices {
                let row = try #require(controller.table.view(atColumn: 0, row: rowIndex, makeIfNecessary: true))
                row.layoutSubtreeIfNeeded()
                #expect(row.superview != nil)
            }
            controller.table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: session.messages.indices))
            controller.table.layoutSubtreeIfNeeded()
            await nextMainTurn()
            let finalRow = try #require(controller.table.view(atColumn: 0, row: 3, makeIfNecessary: true))
            if completed {
                #expect(messageField(in: finalRow)?.attributedStringValue.string == session.messages[3].text.string)
            } else {
                #expect(textView(in: finalRow)?.string == session.messages[3].text.string)
            }
        }
        session.stop()
    }

    @Test(arguments: [false, true])
    func hostedSidebarToggleAcrossCompletionKeepsNativeCells(lightAppearance: Bool) async throws {
        let session = DemoSession()
        let presentation = SidebarPresentation()
        let hosting = NSHostingView(rootView: SidebarHarness(session: session, presentation: presentation))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: lightAppearance ? .aqua : .darkAqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        await nextMainTurn()
        let token = try #require(session.begin("Hello"))
        session.receive("## Demo response\n\nA partial response.", for: token)
        hosting.layoutSubtreeIfNeeded()
        await nextMainTurn()
        let streamingTable = try #require(demoTable(in: hosting))
        let streamingRow = try #require(streamingTable.view(atColumn: 0, row: 3, makeIfNecessary: true))
        presentation.visibility = .detailOnly
        hosting.layoutSubtreeIfNeeded()
        await nextMainTurn()
        session.receive("\n\n" + DemoSession.responseChunks.joined(), for: token)
        session.finish(token)
        hosting.layoutSubtreeIfNeeded()
        await nextMainTurn()
        presentation.visibility = .all
        hosting.layoutSubtreeIfNeeded()
        await nextMainTurn()
        let table = try #require(demoTable(in: hosting))
        for rowIndex in session.messages.indices {
            let row = try #require(table.view(atColumn: 0, row: rowIndex, makeIfNecessary: true))
            #expect(row is NSTableCellView)
            #expect(row.identifier != nil)
        }
        #expect(table.numberOfRows == session.messages.count)
        let finalRow = try #require(table.view(atColumn: 0, row: 3, makeIfNecessary: true))
        #expect(table === streamingTable)
        #expect(finalRow === streamingRow)
        #expect(messageField(in: finalRow)?.attributedStringValue.string == session.messages[3].text.string)
        for size in [NSSize(width: 640, height: 440), NSSize(width: 1200, height: 800)] {
            window.setContentSize(size)
            hosting.layoutSubtreeIfNeeded()
            await nextMainTurn()
            #expect(
                hosting.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (lightAppearance ? .aqua : .darkAqua)
            )
            #expect(table.numberOfRows == session.messages.count)
            let row = try #require(table.view(atColumn: 0, row: 3, makeIfNecessary: true))
            #expect(messageField(in: row)?.attributedStringValue.string == session.messages[3].text.string)
            #expect(row.superview != nil)
        }
    }

    private func demoTable(in view: NSView) -> DemoTableView? {
        if let table = view as? DemoTableView { return table }
        return view.subviews.lazy.compactMap { demoTable(in: $0) }.first
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func host(_ controller: DemoTranscriptController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        controller.scroll.frame = window.contentLayoutRect
        controller.table.frame.size.width = 600
        window.contentView = controller.scroll
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    @Test func onlyReadersNearTheBottomFollowStreaming() {
        #expect(
            DemoTranscriptController.followsBottom(
                documentHeight: 1000,
                visibleRect: NSRect(x: 0, y: 600, width: 500, height: 400)
            )
        )
        #expect(
            DemoTranscriptController.followsBottom(
                documentHeight: 1000,
                visibleRect: NSRect(x: 0, y: 577, width: 500, height: 400)
            )
        )
        #expect(
            !DemoTranscriptController.followsBottom(
                documentHeight: 1000,
                visibleRect: NSRect(x: 0, y: 100, width: 500, height: 400)
            )
        )
    }
}

@MainActor @Observable
private final class SidebarPresentation {
    var visibility: NavigationSplitViewVisibility = .all
}

private struct SidebarHarness: View {
    let session: DemoSession
    @Bindable var presentation: SidebarPresentation

    var body: some View {
        NavigationSplitView(columnVisibility: $presentation.visibility) {
            List { Text("Demo session") }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            DemoTranscript(session: session)
        }
    }
}
