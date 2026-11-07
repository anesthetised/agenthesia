import ACP
import AppKit
import Foundation
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// *Done* clears once the end of the finished turn was on screen (ADR-0026's amendment).
@MainActor @Suite struct TranscriptResultTests {
    @Test func aRowsEndIsOnScreenWhenItsBottomEdgeIsInTheViewport() {
        let visible = NSRect(x: 0, y: 1_000, width: 600, height: 500)
        let shows = { (minY: CGFloat, height: CGFloat) in
            TranscriptTableController.showsEnd(of: NSRect(x: 0, y: minY, width: 600, height: height), in: visible)
        }
        #expect(shows(1_100, 200))
        // Partly visible: the end counts, the top of an answer taller than the viewport does not.
        #expect(shows(400, 800))
        #expect(!shows(1_400, 800))
        // Within the tolerance below the viewport, as for following the bottom.
        #expect(shows(1_400, 124))
        #expect(!shows(1_400, 125))
        // Scrolled away, above or below.
        #expect(!shows(100, 200))
        #expect(!shows(2_000, 200))
        // A clip view that shrinks, as when the permission card docks, or grows again.
        let row = NSRect(x: 0, y: 1_300, width: 600, height: 150)
        #expect(!TranscriptTableController.showsEnd(of: row, in: NSRect(x: 0, y: 1_000, width: 600, height: 300)))
        #expect(TranscriptTableController.showsEnd(of: row, in: NSRect(x: 0, y: 1_000, width: 600, height: 450)))
    }

    @Test func aFoldedGroupsSummaryShowsItsCalls() {
        let folded: [TranscriptRow] = [.item(0), .group(first: 1), .item(4)]
        #expect(TranscriptRow.row(showing: 0, in: folded) == 0)
        #expect(TranscriptRow.row(showing: 2, in: folded) == 1)
        #expect(TranscriptRow.row(showing: 3, in: folded) == 1)
        #expect(TranscriptRow.row(showing: 4, in: folded) == 2)
        let expanded: [TranscriptRow] = [.item(0), .group(first: 1), .item(1), .item(2), .item(3), .item(4)]
        #expect(TranscriptRow.row(showing: 1, in: expanded) == 2)
        #expect(TranscriptRow.row(showing: 3, in: expanded) == 4)
        #expect(TranscriptRow.row(showing: 0, in: []) == nil)
    }

    @Test func anItemsIdentityResolvesToTheRowThatShowsIt() async throws {
        let recorded = try await RecordedTranscript()
        try await recorded.apply(.userMessageChunk(.init(content: .init(text: "Go"))))
        try await recorded.apply(tool("a"))
        try await recorded.apply(tool("b"))
        let source = LiveTranscriptSource()
        publish(recorded, to: source)
        let ids = source.state.items.map(\.id)
        #expect(source.rows == [.item(0), .group(first: 1)])
        #expect(source.row(ofItem: ids[2]) == 1)
        source.toggleExpansion(at: 1)
        #expect(source.row(ofItem: ids[2]) == 3)
        // An item that is not displayed yet has no row.
        #expect(source.row(ofItem: (ids.last ?? 0) + 1) == nil)
    }

    @Test func doneStaysWhileTheResultIsOffScreenAndClearsWhenItScrollsIn() async throws {
        let (recorded, source) = try await longTranscript()
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(source)
        #expect(try await eventually(controller) { settled(controller) })
        var shown: [Int64] = []
        controller.resultShown = { shown.append($0) }
        let target = try #require(recorded.state.items.last?.id)
        let last = controller.table.numberOfRows - 1

        scroll(controller, to: 0)
        controller.unseenResult = target
        #expect(try await eventually(controller) { controller.resultChecks > 0 })
        // The top of the long answer shows, not its end.
        let checks = controller.resultChecks
        scroll(controller, to: controller.table.rect(ofRow: last).minY - 100)
        #expect(try await eventually(controller) { controller.resultChecks > checks })
        #expect(shown.isEmpty && controller.unseenResult == target)

        scroll(controller, to: controller.table.rect(ofRow: last).maxY - 300)
        #expect(try await eventually(controller) { shown == [target] })
        #expect(controller.unseenResult == nil)

        // The jump to the end resumes following and shows a waiting result.
        scroll(controller, to: 0)
        controller.unseenResult = target
        controller.scrollToEnd()
        #expect(try await eventually(controller) { shown == [target, target] })
        #expect(controller.followsEnd)
    }

    @Test func aSmallScrollThatReachesTheEndShowsTheResult() async throws {
        let (recorded, source) = try await longTranscript()
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(source)
        #expect(try await eventually(controller) { settled(controller) })
        var shown: [Int64] = []
        controller.resultShown = { shown.append($0) }
        let clip = controller.scroll.contentView
        let end = controller.table.rect(ofRow: controller.table.numberOfRows - 1).maxY
        // The end 40 pt below the viewport, then 20 pt: within the tolerance, and no row is added.
        scroll(controller, to: end - 40 - clip.bounds.height)
        controller.unseenResult = try #require(recorded.state.items.last?.id)
        #expect(try await eventually(controller) { controller.resultChecks > 0 })
        #expect(shown.isEmpty)
        scroll(controller, to: end - 20 - clip.bounds.height)
        #expect(try await eventually(controller) { shown.count == 1 })
    }

    @Test func aClipViewThatGrowsShowsTheResultWithoutScrolling() async throws {
        let (recorded, source) = try await longTranscript()
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(source)
        #expect(try await eventually(controller) { settled(controller) })
        var shown: [Int64] = []
        controller.resultShown = { shown.append($0) }
        let clip = controller.scroll.contentView
        // Shrunk as the docked card does, with the end 100 pt below the viewport.
        controller.scroll.frame.size.height -= 200
        let end = controller.table.rect(ofRow: controller.table.numberOfRows - 1).maxY
        scroll(controller, to: end - 100 - clip.bounds.height)
        controller.unseenResult = try #require(recorded.state.items.last?.id)
        #expect(try await eventually(controller) { controller.resultChecks > 0 })
        #expect(shown.isEmpty)

        controller.scroll.frame.size.height += 200
        #expect(try await eventually(controller) { shown.count == 1 })
    }

    @Test func aResultShowsOnceItsItemIsDisplayed() async throws {
        let recorded = try await RecordedTranscript()
        try await recorded.apply(.userMessageChunk(.init(content: .init(text: "Go"))))
        let source = LiveTranscriptSource()
        publish(recorded, to: source)
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(source)
        var shown: [Int64] = []
        controller.resultShown = { shown.append($0) }
        // The session's last item is published with the next frame; the transcript is too short to scroll.
        try await recorded.apply(.agentMessageChunk(.init(content: .init(text: "Done"))))
        let target = try #require(recorded.state.items.last?.id)
        controller.unseenResult = target
        #expect(try await eventually(controller) { controller.resultChecks > 0 })
        #expect(shown.isEmpty)
        publish(recorded, to: source)
        controller.update(source)
        #expect(try await eventually(controller) { shown == [target] })
    }

    @Test func nothingIsCheckedWhileNoResultIsUnseen() async throws {
        let (recorded, source) = try await longTranscript()
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(source)
        #expect(try await eventually(controller) { settled(controller) })
        for chunk in 1...5 {
            try await recorded.apply(.agentMessageChunk(.init(content: .init(text: " more \(chunk)"))))
            publish(recorded, to: source)
            controller.update(source)
            scroll(controller, to: CGFloat(chunk) * 50)
            try await Task.sleep(for: .milliseconds(20))
        }
        controller.scroll.frame.size.height -= 100
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.resultChecks == 0)

        // Once shown, the result is reported once and the table stops watching.
        controller.resultShown = { _ in }
        controller.unseenResult = try #require(recorded.state.items.last?.id)
        controller.scrollToEnd()
        #expect(try await eventually(controller) { controller.unseenResult == nil })
        let checks = controller.resultChecks
        scroll(controller, to: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.resultChecks == checks)
    }

    /// A prompt, a long answer, a tool call and a second answer taller than the viewport, which ends the turn.
    private func longTranscript() async throws -> (RecordedTranscript, LiveTranscriptSource) {
        let recorded = try await RecordedTranscript()
        let paragraphs = (1...40).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        try await recorded.apply(.userMessageChunk(.init(content: .init(text: "Go"))))
        try await recorded.apply(.agentMessageChunk(.init(content: .init(text: paragraphs))))
        try await recorded.apply(tool("a"))
        try await recorded.apply(.agentMessageChunk(.init(content: .init(text: paragraphs))))
        let source = LiveTranscriptSource()
        publish(recorded, to: source)
        return (recorded, source)
    }

    private func tool(_ id: String) -> ACP.SessionUpdate {
        .toolCall(.init(toolCallId: id, title: "Call \(id)", kind: .execute, status: .completed))
    }

    private func publish(_ recorded: RecordedTranscript, to source: LiveTranscriptSource) {
        source.state = recorded.state
        source.revision += 1
    }

    /// A reader's scroll: following the end stops, as for a live scroll.
    private func scroll(_ controller: TranscriptTableController, to y: CGFloat) {
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: controller.scroll)
        controller.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        controller.scroll.reflectScrolledClipView(controller.scroll.contentView)
    }

    /// Rows start at an estimated height: wait until the last answer measured taller than the viewport and the table
    /// followed it to the end.
    private func settled(_ controller: TranscriptTableController) -> Bool {
        controller.table.layoutSubtreeIfNeeded()
        let clip = controller.scroll.contentView.bounds
        let last = controller.table.numberOfRows - 1
        return last >= 0 && controller.table.rect(ofRow: last).height > clip.height
            && controller.table.frame.height - clip.maxY < 2
    }

    /// Checks run on a later main-queue turn, which is slower on CI. It does not lay out, so that only the table's own
    /// observers trigger them.
    private func eventually(_ controller: TranscriptTableController, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func host(_ controller: TranscriptTableController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // In a container, so that tests can resize the scroll view as the docked card does.
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        controller.scroll.frame = container.bounds
        controller.table.frame.size.width = 600
        container.addSubview(controller.scroll)
        container.layoutSubtreeIfNeeded()
        return window
    }
}
