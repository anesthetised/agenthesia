import ACP
import AppKit
import Foundation
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// The transcript side of ADR-0039's amendment *a pending permission docks above the composer*: a one-line record
/// with Details, a tool row that leaves its diff to the docked card while its request is pending, and no buttons.
@MainActor @Suite struct PermissionRecordTests {
    private static let options: [ACP.PermissionOption] = [
        .init(optionId: "allow", name: "Allow", kind: .allowOnce),
        .init(optionId: "reject", name: "Reject", kind: .rejectOnce),
    ]
    private static let diff = ACP.Diff(
        path: "note.txt",
        oldText: (1...30).map { "old \($0)" }.joined(separator: "\n"),
        newText: (1...30).map { "new \($0)" }.joined(separator: "\n")
    )

    private func pending(_ id: UUID, call: String = "t") -> SessionController.PendingPermission {
        .init(
            id: id,
            options: Self.options,
            toolTitle: nil,
            callTitle: nil,
            toolCall: .init(toolCallId: ACP.ToolCallID(call), title: "Write note.txt")
        )
    }

    /// A write with a diff, its request, and optionally the answer.
    private func transcript(
        outcome: ACP.PermissionOutcome? = nil,
        id: UUID = UUID()
    ) async throws -> RecordedTranscript {
        let recorded = try await RecordedTranscript()
        try await recorded.apply(
            .toolCall(
                .init(
                    toolCallId: "t",
                    title: "Write note.txt",
                    kind: .edit,
                    status: .pending,
                    content: [.diff(Self.diff)]
                )
            )
        )
        try await recorded.append(
            try SessionEvent.permissionRequested(id: id, toolCall: .init(toolCallId: "t"), options: Self.options)
                .storedEvent()
        )
        if let outcome {
            try await recorded.append(try SessionEvent.permissionResolved(id: id, outcome: outcome).storedEvent())
        }
        return recorded
    }

    private func source(
        _ recorded: RecordedTranscript,
        pending: [SessionController.PendingPermission] = []
    )
        -> LiveTranscriptSource
    {
        let source = LiveTranscriptSource()
        source.pending = pending
        source.state = recorded.state
        source.revision += 1
        return source
    }

    @Test(arguments: [
        (ACP.PermissionOutcome.selected("allow"), "Allowed once", ToolCardHeader.Tone.success),
        (.selected("reject"), "Rejected once", .failure),
        (.cancelled, "Cancelled", .neutral),
    ])
    func aDecidedRequestIsOneLineWithADetailsDisclosure(
        outcome: ACP.PermissionOutcome,
        status: String,
        tone: ToolCardHeader.Tone
    ) async throws {
        let live = source(try await transcript(outcome: outcome))
        let row = live.message(at: 1)
        #expect(row.kind == .group && row.markdown.isEmpty)
        #expect(row.tool?.status == status && row.tool?.tone == tone)
        #expect(row.tool?.kind == "· Edit · Write note.txt")
        #expect(row.tool?.expandable == true && row.tool?.expanded == false)

        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(live)
        let view = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        #expect(labels(in: view) == [status, "· Edit · Write note.txt"])
        let disclosure = try #require(views(NSButton.self, in: view).first { $0.bezelStyle == .disclosure })
        #expect(disclosure.accessibilityLabel() == "Details")
        // The folded record is a header and nothing else; the call's text is behind Details.
        #expect(!labels(in: view).contains { $0.contains("Returned") || $0.contains("Request cancelled") })
    }

    @Test func detailsShowTheCallAndTheOutcomeAndFoldAgain() async throws {
        let live = source(try await transcript(outcome: .selected("allow")))
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(live)
        let folded = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        controller.toggleExpansion(
            try #require(views(NSButton.self, in: folded).first { $0.bezelStyle == .disclosure })
        )

        let shown = live.message(at: 1)
        #expect(shown.kind == .card && shown.tool?.expanded == true)
        #expect(shown.markdown.hasPrefix("Edit · **Write note.txt**"))
        #expect(shown.markdown.contains("new 30") && shown.markdown.hasSuffix("Returned “Allow” to the agent."))
        let row = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let disclosure = try #require(views(NSButton.self, in: row).first { $0.bezelStyle == .disclosure })
        #expect(disclosure.accessibilityLabel() == "Hide details" && disclosure.state == .on)
        #expect(labels(in: row).first == "Allowed once")

        controller.toggleExpansion(disclosure)
        #expect(live.message(at: 1).markdown.isEmpty && live.message(at: 1).kind == .group)
        let again = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        #expect(labels(in: again) == ["Allowed once", "· Edit · Write note.txt"])
    }

    @Test func aPendingRequestReadsWaitingForYouAndTurnsIntoItsAnswer() async throws {
        let id = UUID()
        let recorded = try await transcript(id: id)
        let live = source(recorded, pending: [pending(id)])
        live.running = true
        #expect(live.message(at: 1).tool?.status == "Waiting for you")
        #expect(live.message(at: 1).tool?.tone == .attention)
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(live)
        let row = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        #expect(labels(in: row) == ["Waiting for you", "· Edit · Write note.txt"])

        try await recorded.append(
            try SessionEvent.permissionResolved(id: id, outcome: .selected("allow")).storedEvent()
        )
        live.pending = []
        live.state = recorded.state
        live.revision += 1
        controller.update(live)
        let answered = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        #expect(labels(in: answered) == ["Allowed once", "· Edit · Write note.txt"])
        #expect(live.message(at: 1).tool?.tone == .success)
    }

    @Test func noButtonsAnswerFromTheTable() async throws {
        let first = UUID()
        let recorded = try await transcript(id: first)
        let second = UUID()
        try await recorded.append(
            try SessionEvent.permissionRequested(id: second, toolCall: .init(toolCallId: "t"), options: Self.options)
                .storedEvent()
        )
        let live = source(recorded, pending: [pending(first), pending(second)])
        live.running = true
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(live)
        for index in 0..<controller.table.numberOfRows {
            let row = try #require(controller.table.view(atColumn: 0, row: index, makeIfNecessary: true))
            #expect(!views(NSButton.self, in: row).contains { $0.bezelStyle == .push })
            #expect(!labels(in: row).contains("Allow") && !labels(in: row).contains("Reject"))
        }
    }

    @Test func theStatusAndTheSummaryReadAsOnePhrase() async throws {
        let id = UUID()
        let live = source(try await transcript(id: id), pending: [pending(id)])
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(live)
        let rows = (0..<controller.table.numberOfRows).compactMap {
            controller.table.view(atColumn: 0, row: $0, makeIfNecessary: true)
        }
        let status = try #require(
            rows.lazy.flatMap { self.views(NSTextField.self, in: $0) }.first {
                $0.stringValue == "Waiting for you"
            }
        )
        let header = try #require(status.superview as? NSStackView)
        #expect(header.customSpacing(after: status) < header.spacing)
    }

    @Test func copyReturnsTheRecordWithItsDetailsWhetherOrNotItIsFolded() async throws {
        let live = source(try await transcript(outcome: .cancelled))
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(live)
        let markdown = try #require(live.message(at: 1).copyText?())
        #expect(markdown.hasPrefix("Edit · **Write note.txt**") && markdown.contains("new 30"))
        #expect(markdown.hasSuffix("Request cancelled; no option was returned to the agent."))
        controller.table.selectRowIndexes([1], byExtendingSelection: false)
        #expect(controller.selectedMarkdown == markdown)
        // Expanded, the row's own text is the same Markdown.
        live.toggleExpansion(at: 1)
        #expect(live.message(at: 1).markdown == markdown)
        #expect(live.message(at: 1).copyText?() == markdown)
    }

    @Test func theToolRowLeavesItsDiffToTheDockedCardWhileItsRequestIsPending() async throws {
        let id = UUID()
        let recorded = try await transcript(id: id)
        let live = source(recorded, pending: [pending(id)])
        let hidden = live.message(at: 0)
        #expect(!hidden.markdown.contains("```diff") && hidden.markdown == "**Write note.txt**")
        // A request for another call leaves this row alone.
        live.pending = [pending(id, call: "other")]
        #expect(live.message(at: 0).markdown.contains("```diff"))
        live.pending = [pending(id)]
        #expect(!live.message(at: 0).markdown.contains("```diff"))
        // Copy still returns the whole call.
        #expect(live.message(at: 0).copyText?().contains("new 30") == true)

        live.pending = []
        let restored = live.message(at: 0)
        #expect(restored.markdown.contains("```diff") && restored.markdown.contains("-old 1"))
    }

    @Test func aRowThatRestoresItsDiffKeepsTheTableFollowingTheEnd() async throws {
        let id = UUID()
        let recorded = try await longTranscript(id: id)
        let live = LiveTranscriptSource()
        live.running = true
        live.pending = [pending(id)]
        live.state = recorded.state
        live.revision += 1
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(live)
        #expect(try await reachesEnd(controller))
        let before = controller.table.frame.height

        try await answer(id, in: recorded, live: live, controller: controller)
        #expect(try await grows(controller, from: before))
        #expect(try await reachesEnd(controller))
    }

    @Test func aRowThatRestoresItsDiffKeepsAScrolledBackPlace() async throws {
        let id = UUID()
        let recorded = try await longTranscript(id: id)
        let live = LiveTranscriptSource()
        live.running = true
        live.pending = [pending(id)]
        live.state = recorded.state
        live.revision += 1
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(live)
        #expect(try await reachesEnd(controller))

        controller.scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        controller.scroll.reflectScrolledClipView(controller.scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: controller.scroll)
        let before = controller.table.frame.height
        try await answer(id, in: recorded, live: live, controller: controller)
        #expect(try await grows(controller, from: before))
        #expect(abs(controller.scroll.contentView.bounds.origin.y - 40) < 1)
    }

    // MARK: - Helpers

    /// A long agent message first, so the transcript scrolls; the write and its pending request follow.
    private func longTranscript(id: UUID) async throws -> RecordedTranscript {
        let recorded = try await RecordedTranscript()
        let text = (1...60).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        try await recorded.apply(.agentMessageChunk(.init(content: .init(text: text))))
        try await recorded.apply(
            .toolCall(
                .init(
                    toolCallId: "t",
                    title: "Write note.txt",
                    kind: .edit,
                    status: .pending,
                    content: [.diff(Self.diff)]
                )
            )
        )
        try await recorded.append(
            try SessionEvent.permissionRequested(id: id, toolCall: .init(toolCallId: "t"), options: Self.options)
                .storedEvent()
        )
        return recorded
    }

    private func answer(
        _ id: UUID,
        in recorded: RecordedTranscript,
        live: LiveTranscriptSource,
        controller: TranscriptTableController
    ) async throws {
        try await recorded.append(
            try SessionEvent.permissionResolved(id: id, outcome: .selected("allow")).storedEvent()
        )
        live.pending = []
        live.state = recorded.state
        live.revision += 1
        controller.update(live)
    }

    /// A restored diff makes its row taller once the table lays out again, which a loaded runner may delay.
    private func grows(_ controller: TranscriptTableController, from height: CGFloat) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            controller.table.layoutSubtreeIfNeeded()
            if controller.table.frame.height > height { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// New rows measure themselves during layout, and the table follows them on the next main queue turn.
    private func reachesEnd(_ controller: TranscriptTableController) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            controller.table.layoutSubtreeIfNeeded()
            if controller.table.frame.height - controller.scroll.contentView.bounds.maxY < 2 { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func host(_ controller: TranscriptTableController, width: CGFloat = 600) -> NSWindow {
        let window = OffscreenWindow(size: .init(width: width, height: 600))
        controller.scroll.frame = window.contentLayoutRect
        controller.table.frame.size.width = width
        window.contentView = controller.scroll
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func views<View: NSView>(_ type: View.Type, in view: NSView) -> [View] {
        ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The row's text labels; the title a bordered button draws is not one.
    private func labels(in view: NSView) -> [String] {
        views(NSTextField.self, in: view).filter { !($0.superview is NSButton) }.map(\.stringValue)
    }
}
