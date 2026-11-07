import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// Ask agent from the review pane's diff to the composer (ADR-0041), in a window with a MockAgent session.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AskAgentTests {
    @Test func askAgentAndTheContextMenuQuoteTheSelectionAtTheCaret() async throws {
        let fixture = try await MergeWindowTests().fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        let greeting = URL(filePath: fixture.record.workingDirectory).appending(path: "greeting")
        try "hello\nworld\n".write(to: greeting, atomically: true, encoding: .utf8)
        #expect(!model.canAskAgent)
        #expect(model.askAgentHelp == "Select lines in the diff to quote them in the message (⌥⌘A)")
        await model.files.attach(fixture.record)
        model.toggleReview()
        let review = try #require(model.review)
        await review.refresh()

        _ = NSApplication.shared
        let host = NSHostingView(rootView: RootView(model: model))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await waitUntil(host) { model.reviewDiff?.lines.isEmpty == false && composer(in: host) != nil }
        let diff = try #require(model.reviewDiff)
        let text = try #require(composer(in: host))
        #expect(diff.string == "@@ -0,0 +1,2 @@\n+hello\n+world")

        // The caret sits inside the draft; the quote goes there and the draft stays around it.
        model.composer.message.text = "Hi there"
        try await waitUntil(host) { text.string == "Hi there" }
        text.setSelectedRange(NSRange(location: 2, length: 0))
        window.makeFirstResponder(diff)
        diff.setSelectedRange(NSRange(location: diff.lineStarts[1] + 2, length: 1))
        #expect(review.hasSelection && model.canAskAgent)
        #expect(model.askAgentHelp == "Quote the selected lines in the message (⌥⌘A)")
        let quote = "`greeting:1`\n```diff\n+hello\n```"

        // The footer's button and ⌥⌘A call this; SwiftUI's buttons and menu commands cannot be pressed in a test.
        model.askAgent()
        try await waitUntil(host) { text.string == "Hi\n\(quote)\n there" && window.firstResponder === text }
        #expect(model.composer.message.text == text.string)
        // Nothing was sent.
        #expect(fixture.owner.controller?.queuedPrompts.isEmpty == true)

        // The file changes while the selection holds the diff: the context menu's quote says so.
        try "hello\nthere\nworld\n".write(to: greeting, atomically: true, encoding: .utf8)
        await review.refresh()
        try await waitUntil(host) { review.isHolding }
        #expect(diff.selectedRange().length == 1)
        // A right-click outside the selection would select the clicked word.
        let selected = window.convertFromScreen(
            diff.firstRect(forCharacterRange: diff.selectedRange(), actualRange: nil)
        )
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: NSPoint(x: selected.midX, y: selected.midY),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        let item = try #require(diff.menu(for: event)?.items.first)
        #expect(item.title == "Ask Agent" && item.toolTip == model.askAgentHelp && diff.validateMenuItem(item))
        window.makeFirstResponder(diff)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        let stale = quote + "\n(from an earlier version; lines may have moved)"
        try await waitUntil(host) { text.string == "Hi\n\(quote)\n\(stale)\n there" && window.firstResponder === text }
    }

    @Test func askAgentIsDisabledWhenTheSessionCannotTakeAPrompt() async throws {
        let fixture = try await MergeWindowTests().fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        try "hello\n".write(
            to: URL(filePath: fixture.record.workingDirectory).appending(path: "greeting"),
            atomically: true,
            encoding: .utf8
        )
        await model.files.attach(fixture.record)
        model.toggleReview()
        let review = try #require(model.review)
        await review.refresh()
        review.hasSelection = true
        #expect(model.promptUnavailableReason == nil && model.canAskAgent)
        await model.endSession()
        let controller = try #require(fixture.owner.controller)
        try await waitUntil { controller.status == .closed }
        #expect(model.isReviewShown && review.hasSelection)
        #expect(!model.canAskAgent)
        #expect(model.askAgentHelp == "Session ended: the session cannot take a prompt")
        model.askAgent()
        #expect(model.composerInsertion == nil && model.composerFocusRequests == 0)
    }

    private func composer(in view: NSView) -> FileTextView? {
        if let text = view as? FileTextView { return text }
        return view.subviews.lazy.compactMap { composer(in: $0) }.first
    }

    private func waitUntil(
        _ host: NSView? = nil,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out", sourceLocation: sourceLocation)
            try await Task.sleep(for: .milliseconds(10))
            host?.layoutSubtreeIfNeeded()
        }
    }
}
