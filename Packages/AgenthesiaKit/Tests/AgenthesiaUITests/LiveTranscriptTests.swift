import ACP
import AppKit
import Foundation
import JSONRPC
import Persistence
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite struct LiveTranscriptTests {
    @Test func cachedRenderingHandlesAppendsReplacementsAndUnicode() {
        let source = LiveTranscriptSource()
        let first = source.render(id: 1, role: "Agent", markdown: "Hello 🌍")
        let unchanged = source.render(id: 1, role: "Agent", markdown: "Hello 🌍")
        #expect(unchanged.text === first.text)
        let appended = source.render(id: 1, role: "Agent", markdown: "Hello 🌍 **world**")
        #expect(appended.text.string == "Hello 🌍 world")
        let copy = NSMutableAttributedString(attributedString: first.text)
        appended.update?.apply(to: copy)
        #expect(copy == appended.text)
        #expect(first.text.string == "Hello 🌍")
        let replacement = source.render(id: 1, role: "Agent", markdown: "Different")
        #expect(replacement.previousMarkdown == nil)
        #expect(replacement.text.string == "Different")
    }

    @Test func contentKeepsRolesAttachmentsToolsAndNoticesVisible() {
        let message = TranscriptState.Item(
            id: 1,
            message: .init(
                role: .thought,
                turnID: nil,
                agentMessageID: nil,
                content: [.init(text: "Thinking"), .image(.init(data: "", mimeType: "image/png"))]
            )
        )
        #expect(LiveTranscriptSource.content(message).0 == "Thinking")
        #expect(LiveTranscriptSource.content(message).1.contains("Image attachment"))
        let tool = TranscriptState.Item(id: 2, toolCall: .init(toolCallId: "t", title: "Read file", status: .completed))
        #expect(LiveTranscriptSource.content(tool) == ("Tool", "**Read file**"))
        #expect(LiveTranscriptSource.content(.init(id: 3, notice: "Interrupted")).1 == "Interrupted")
    }

    @Test func toolCardShowsOnlyWhatTheAgentReported() {
        let unknown = ACP.ToolCall(toolCallId: "t", title: "")
        let (bare, bareMarkdown) = LiveTranscriptSource.toolCard(unknown, permission: nil, expanded: false)
        #expect(
            bare
                == ToolCardHeader(
                    symbol: "wrench.and.screwdriver",
                    kind: "Tool",
                    status: "Status not reported",
                    tone: .neutral
                )
        )
        #expect(bareMarkdown == "_Untitled tool call_")
        let call = ACP.ToolCall(
            toolCallId: "t",
            title: "Edit main.swift",
            kind: .edit,
            status: .failed,
            content: [
                .content(.init(content: .init(text: "Could not apply"))),
                .content(.init(content: .image(.init(data: "", mimeType: "image/png")))),
                .diff(.init(path: "main.swift", oldText: nil, newText: "new")),
                .terminal(.init(terminalId: "term")),
                .unknown(["type": "future"]),
            ],
            locations: [.init(path: "/src/main.swift", line: 4), .init(path: "/src/other.swift")]
        )
        let (header, markdown) = LiveTranscriptSource.toolCard(call, permission: nil, expanded: false)
        #expect(header == ToolCardHeader(symbol: "pencil", kind: "Edit", status: "Failed", tone: .failure))
        #expect(
            markdown == """
                **Edit main.swift**

                - `/src/main.swift:4`
                - `/src/other.swift`

                Could not apply

                [Image attachment]

                [Diff: `main.swift`, new file]

                [Terminal: `term`]

                [Unsupported content]
                """
        )
        let statuses: [ACP.ToolCallStatus] = [.pending, .inProgress, .completed, .unknown("queued")]
        #expect(
            statuses.map { LiveTranscriptSource.status($0).0 } == ["Pending", "Running", "Completed", "queued"]
        )
        #expect(ACP.ToolKind.knownCases.map { LiveTranscriptSource.kind($0).label }.count == 10)
        #expect(LiveTranscriptSource.kind(.unknown("deploy")).label == "deploy")
    }

    @Test func permissionOutcomesClaimOnlyWhatWasRecorded() {
        let call = ACP.ToolCall(toolCallId: "t", title: "Write")
        func text(_ outcome: ACP.PermissionOutcome) -> String {
            LiveTranscriptSource.toolCard(call, permission: outcome, expanded: false).markdown
        }
        #expect(text(.cancelled).hasSuffix("Permission request cancelled."))
        #expect(text(.selected("reject")).hasSuffix("Permission answered with option “reject”."))
        #expect(text(.unknown(["outcome": "later"])).hasSuffix("Unrecognized permission outcome."))
        #expect(![text(.cancelled), text(.selected("allow"))].contains { $0.contains("declined") })
    }

    @Test func largeToolContentIsBoundedUntilExpanded() throws {
        let output = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let call = ACP.ToolCall(
            toolCallId: "t",
            title: "Search",
            content: [.content(.init(content: .init(text: "```\n\(output)\n```")))]
        )
        let (collapsedHeader, collapsed) = LiveTranscriptSource.toolCard(call, permission: nil, expanded: false)
        #expect(collapsedHeader.expandable && !collapsedHeader.expanded)
        #expect(collapsed.contains("line 11\n```\n\n_… 30 more lines_"))
        #expect(!collapsed.contains("line 12"))
        let (expandedHeader, expanded) = LiveTranscriptSource.toolCard(call, permission: nil, expanded: true)
        #expect(expandedHeader.expanded)
        #expect(expanded.hasSuffix("line 40\n```"))
        let wide = try #require(LiveTranscriptSource.collapse(String(repeating: "x", count: 3_000)))
        #expect(wide == String(repeating: "x", count: 2_000) + "\n\n_… truncated_")
        #expect(LiveTranscriptSource.collapse("short") == nil)
        #expect(
            LiveTranscriptSource.collapse(Array(repeating: "a", count: 13).joined(separator: "\n"))?.hasSuffix(
                "1 more line_"
            ) == true
        )
    }

    @Test func toolCardChangesInPlaceAndKeepsExpansionAndSelection() async throws {
        let recorded = try await RecordedTranscript()
        let turn = UUID()
        let output = (1...40).map { "line \($0)" }.joined(separator: "\n")
        try await recorded.append(try SessionEvent.prompt(id: turn, content: [.init(text: "tools")]).storedEvent())
        try await recorded.apply(.toolCallUpdate(.init(toolCallId: "t", status: .inProgress)))
        try await recorded.apply(
            .toolCall(
                .init(
                    toolCallId: "t",
                    title: "Run",
                    kind: .execute,
                    content: [.content(.init(content: .init(text: output)))]
                )
            )
        )
        try await recorded.apply(.agentMessageChunk(.init(content: .init(text: "Earlier paragraph.\n\nStreaming"))))
        let source = LiveTranscriptSource()
        source.running = true
        func publish() {
            source.state = recorded.state
            source.revision += 1
        }
        publish()
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(source)

        let toolRow = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        #expect(labels(in: toolRow).contains("Running"))
        let disclosure = try #require(views(NSButton.self, in: toolRow).first { $0.bezelStyle == .disclosure })
        controller.toggleExpansion(disclosure)
        #expect(source.message(at: 1).markdown.contains("line 40"))
        let answerRow = try #require(controller.table.view(atColumn: 0, row: 2, makeIfNecessary: true))
        let answer = try #require(views(NSTextView.self, in: answerRow).first)
        answer.setSelectedRange(NSRange(location: 0, length: 9))
        controller.table.selectRowIndexes([0], byExtendingSelection: false)

        try await recorded.apply(.toolCallUpdate(.init(toolCallId: "t", status: .completed)))
        try await recorded.apply(.agentMessageChunk(.init(content: .init(text: " continues"))))
        publish()
        controller.update(source)
        #expect(source.state.items.count == 3)
        let updatedRow = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        #expect(labels(in: updatedRow).contains("Completed"))
        #expect(source.message(at: 1).tool?.expanded == true)
        #expect(answer.string == "Earlier paragraph.\nStreaming continues")
        #expect(answer.selectedRange() == NSRange(location: 0, length: 9))
        #expect(controller.table.selectedRowIndexes == [0])
    }

    private func host(_ controller: TranscriptTableController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
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

    private func views<View: NSView>(_ type: View.Type, in view: NSView) -> [View] {
        ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private func labels(in view: NSView) -> [String] { views(NSTextField.self, in: view).map(\.stringValue) }
}

/// Builds transcript state from stored events, exactly as live sessions and replay do.
private final class RecordedTranscript {
    let directory = FileManager.default.temporaryDirectory.appending(path: "transcript-\(UUID())")
    let store: PersistenceStore
    let session: SessionRecord
    var state = TranscriptState()

    init() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try PersistenceStore(databaseURL: directory.appending(path: "history.sqlite"))
        let project = ProjectRecord(name: "Test", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Mock", executable: "MockAgent")
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        session = SessionRecord(projectID: project.id, agentInstallID: agent.id, workingDirectory: directory.path)
        try await store.createSession(session)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func append(_ event: NewEvent) async throws {
        for stored in try await store.append([event], to: session.id) { try state.apply(stored) }
    }

    func apply(_ update: ACP.SessionUpdate) async throws {
        let notification = Message.notification(
            method: "session/update",
            params: try JSONValue(encoding: ACP.V1.SessionNotification(sessionId: "s", update: update))
        )
        try await append(NewEvent(kind: SessionEvent.updateKind, payload: try JSONEncoder().encode(notification)))
    }
}
