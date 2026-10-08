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
        let (bare, bareMarkdown) = LiveTranscriptSource.toolCard(unknown, expanded: false)
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
        let (header, markdown) = LiveTranscriptSource.toolCard(call, expanded: false)
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
        let call = ACP.ToolCall(toolCallId: "t", title: "Write", kind: .edit)
        let options: [ACP.PermissionOption] = [
            .init(optionId: "once", name: "Allow", kind: .allowOnce),
            .init(optionId: "always", name: "Always allow", kind: .allowAlways),
            .init(optionId: "no", name: "Reject", kind: .rejectOnce),
            .init(optionId: "never", name: "Never", kind: .rejectAlways),
            .init(optionId: "later", name: "Ask later", kind: .unknown("ask_later")),
        ]
        func card(
            _ outcome: ACP.PermissionOutcome?,
            options: [ACP.PermissionOption] = options,
            phase: LiveTranscriptSource.PermissionPhase = .ended
        ) -> (header: ToolCardHeader, markdown: String) {
            LiveTranscriptSource.permissionCard(
                .init(requestID: UUID(), toolCall: call, options: options, outcome: outcome),
                phase: phase,
                expanded: false
            )
        }
        #expect(card(nil).markdown.hasPrefix("Edit · **Write**"))
        #expect(card(.selected("once")).header.status == "Allowed once")
        #expect(card(.selected("once")).markdown.hasSuffix("Returned “Allow” to the agent."))
        #expect(card(.selected("always")).header.status == "Always allowed")
        #expect(card(.selected("always")).markdown.hasSuffix("The agent may apply it to later requests."))
        #expect(card(.selected("no")).header.status == "Rejected once")
        #expect(card(.selected("never")).header.status == "Always rejected")
        #expect(card(.selected("later")).header.status == "Answered")
        #expect(card(.selected("later")).header.tone == .neutral)
        // Decisions recorded before requests had their own events name only the option identifier.
        #expect(card(.selected("reject"), options: []).markdown.hasSuffix("Answered with option “reject”."))
        #expect(card(.cancelled).markdown.hasSuffix("Request cancelled; no option was returned to the agent."))
        #expect(card(.unknown(["outcome": "later"])).markdown.hasSuffix("Unrecognized permission outcome."))
        #expect(card(nil).header.status == "No answer")
        #expect(card(nil).header.actions.isEmpty)
        #expect(card(nil, phase: .recording).header.status == "Recording answer")
        #expect(card(nil, phase: .recording).header.actions.isEmpty)
        let choosing = card(nil, phase: .choosing(shortcuts: true))
        #expect(choosing.header.actions == options.map(\.name))
        #expect(choosing.header.shortcuts)
        #expect(choosing.markdown.contains("remembered by the agent, not by Agenthesia"))
        let once = card(nil, options: [options[0], options[2]], phase: .choosing(shortcuts: false))
        #expect(!once.header.shortcuts)
        #expect(!once.markdown.contains("Always"))
        #expect(
            !options.map(\.optionId).map { card(.selected($0)).markdown }.contains { $0.contains("declined") }
        )
        let untitled = LiveTranscriptSource.permissionCard(
            .init(requestID: nil, toolCall: .init(toolCallId: "u", title: ""), options: [], outcome: nil),
            phase: .ended,
            expanded: false
        )
        #expect(untitled.markdown.hasPrefix("Tool · _Untitled tool call_"))
        let item = TranscriptState.Item(
            id: 1,
            permission: .init(requestID: nil, toolCall: call, options: [], outcome: .cancelled)
        )
        #expect(LiveTranscriptSource.content(item).0 == "Permission")
    }

    @Test func pendingPermissionRowsOfferOptionsUntilAnswered() async throws {
        let recorded = try await RecordedTranscript()
        let first = UUID()
        let second = UUID()
        let options: [ACP.PermissionOption] = [
            .init(optionId: "allow", name: "Allow", kind: .allowOnce),
            .init(optionId: "reject", name: "Reject", kind: .rejectOnce),
        ]
        try await recorded.apply(.toolCall(.init(toolCallId: "t", title: "Write file", kind: .edit)))
        for id in [first, second] {
            try await recorded.append(
                try SessionEvent.permissionRequested(id: id, toolCall: .init(toolCallId: "t"), options: options)
                    .storedEvent()
            )
        }
        let source = ChoiceRecorder()
        source.live.running = true
        source.live.pending = [first, second]
        source.live.state = recorded.state
        source.live.revision += 1
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(source)
        let row = try #require(controller.table.view(atColumn: 0, row: 2, makeIfNecessary: true))
        let buttons = views(NSButton.self, in: row).filter {
            $0.action == #selector(TranscriptTableController.choosePermission(_:))
        }
        #expect(buttons.map(\.title) == ["Allow", "Reject"])
        // Only the oldest pending request answers to ⌥⌘1….
        #expect(buttons.map(\.toolTip) == [nil, nil])
        let oldest = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        #expect(views(NSButton.self, in: oldest).compactMap(\.toolTip).contains("⌥⌘2"))
        buttons[1].performClick(nil)
        #expect(source.choices.count == 1)
        #expect(source.choices.first?.row == 2)
        #expect(source.choices.first?.option == 1)

        try await recorded.append(
            try SessionEvent.permissionResolved(id: second, outcome: .selected("reject")).storedEvent()
        )
        source.live.pending = [first]
        source.live.state = recorded.state
        source.live.revision += 1
        controller.update(source)
        let answered = try #require(controller.table.view(atColumn: 0, row: 2, makeIfNecessary: true))
        #expect(!views(NSButton.self, in: answered).contains { $0.title == "Reject" })
        #expect(labels(in: answered).contains("Rejected once"))
        // Without a controller, an answer has nowhere to go and must not crash.
        source.live.choosePermission(at: 1, option: 0)
        source.live.choosePermission(at: 0, option: 0)
    }

    @Test(arguments: [440.0, 600.0]) func permissionOptionsRemainVisibleInNarrowTranscripts(width: Double) async throws
    {
        let recorded = try await RecordedTranscript()
        let id = UUID()
        let names = [
            "Allow this command once", "Always allow commands like this",
            "Reject this command", "Always reject commands like this",
        ]
        let kinds: [ACP.PermissionOptionKind] = [.allowOnce, .allowAlways, .rejectOnce, .rejectAlways]
        let options = names.enumerated().map { index, name in
            ACP.PermissionOption(optionId: "option-\(index)", name: name, kind: kinds[index])
        }
        try await recorded.append(
            try SessionEvent.permissionRequested(
                id: id,
                toolCall: .init(toolCallId: "t", title: "Run command"),
                options: options
            )
            .storedEvent()
        )
        let source = ChoiceRecorder()
        source.live.running = true
        source.live.pending = [id]
        source.live.state = recorded.state
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        window.setContentSize(NSSize(width: width, height: 600))
        controller.scroll.frame = window.contentLayoutRect
        controller.update(source)
        window.contentView?.layoutSubtreeIfNeeded()
        let row = try #require(controller.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let buttons = views(NSButton.self, in: row).filter {
            $0.action == #selector(TranscriptTableController.choosePermission(_:))
        }
        #expect(buttons.map(\.title) == names)
        let viewport = controller.scroll.contentView.bounds
        for (index, button) in buttons.enumerated() {
            let rect = button.convert(button.bounds, to: controller.scroll.contentView)
            #expect(!button.isHiddenOrHasHiddenAncestor)
            #expect(viewport.contains(rect))
            button.performClick(nil)
            #expect(source.choices.last?.row == 0)
            #expect(source.choices.last?.option == index)
        }
    }

    @Test func largeToolContentIsBoundedUntilExpanded() throws {
        let output = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let call = ACP.ToolCall(
            toolCallId: "t",
            title: "Search",
            content: [.content(.init(content: .init(text: "```\n\(output)\n```")))]
        )
        let (collapsedHeader, collapsed) = LiveTranscriptSource.toolCard(call, expanded: false)
        #expect(collapsedHeader.expandable && !collapsedHeader.expanded)
        #expect(collapsed.contains("line 11\n```\n\n_… 30 more lines_"))
        #expect(!collapsed.contains("line 12"))
        let (expandedHeader, expanded) = LiveTranscriptSource.toolCard(call, expanded: true)
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

    @Test(arguments: [
        "```", "~~~", "````", "  ```", "   ~~~~text",
        "````\n```\n~~~\n```` trailing", "~~~\n    ~~~",
        "```\ncode\n```` \t", "~~~\ncode\n~~~", "``` invalid ` info",
        "- ```\n  code\n  ```", "- list\n  ```\n  code",
    ])
    func collapsedCodeFencesKeepNotesOutsideCode(prefix: String) {
        let output = prefix + "\n" + (1...40).map { "line \($0)" }.joined(separator: "\n")
        let call = ACP.ToolCall(
            toolCallId: "t",
            title: "Read",
            content: [.content(.init(content: .init(text: output)))]
        )
        let card = LiveTranscriptSource.permissionCard(
            .init(requestID: nil, toolCall: call, options: [], outcome: .cancelled),
            phase: .ended,
            expanded: false
        )
        let rendered = LiveTranscriptSource().render(id: 1, role: "Permission", markdown: card.markdown).text
        #expect(!rendered.string.contains("_…"))
        let permission = (rendered.string as NSString).range(of: "Request cancelled; no option was returned")
        #expect(permission.location != NSNotFound)
        if permission.location != NSNotFound {
            let font = rendered.attribute(.font, at: permission.location, effectiveRange: nil) as? NSFont
            #expect(font?.isFixedPitch == false)
        }
    }

    @Test func headerOnlyUpdatesPreserveToolBodySelection() async throws {
        let recorded = try await RecordedTranscript()
        try await recorded.apply(
            .toolCall(
                .init(
                    toolCallId: "t",
                    title: "Run",
                    kind: .execute,
                    status: .inProgress,
                    content: [.content(.init(content: .init(text: "Stable output to select")))]
                )
            )
        )
        let source = LiveTranscriptSource()
        source.state = recorded.state
        source.revision += 1
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(source)
        let row = try #require(controller.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let field = try #require(views(NSTextField.self, in: row).first { $0.isSelectable })
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        let selection = NSRange(location: 4, length: 6)
        editor.setSelectedRange(selection)
        for status in [ACP.ToolCallStatus.completed, .failed] {
            try await recorded.apply(.toolCallUpdate(.init(toolCallId: "t", status: status)))
            source.state = recorded.state
            source.revision += 1
            controller.update(source)
            let updatedRow = try #require(controller.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
            let updatedField = try #require(views(NSTextField.self, in: updatedRow).first { $0.isSelectable })
            #expect(labels(in: updatedRow).contains(LiveTranscriptSource.status(status).0))
            #expect(updatedField.stringValue == field.stringValue)
            #expect(updatedField.currentEditor()?.selectedRange == selection)
        }
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

    @Test func changedToolHeaderSurvivesTableResize() async throws {
        let recorded = try await RecordedTranscript()
        let turn = UUID()
        let output = (1...40).map { "line \($0)" }.joined(separator: "\n")
        try await recorded.append(try SessionEvent.prompt(id: turn, content: [.init(text: "tools")]).storedEvent())
        try await recorded.apply(
            .toolCall(
                .init(
                    toolCallId: "t",
                    title: "Run",
                    kind: .execute,
                    status: .inProgress,
                    content: [.content(.init(content: .init(text: output)))]
                )
            )
        )
        try await recorded.apply(.agentMessageChunk(.init(content: .init(text: "Earlier paragraph.\n\nStreaming"))))
        let source = LiveTranscriptSource()
        source.running = true
        func publish() { source.state = recorded.state; source.revision += 1 }
        publish()
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(source)
        _ = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        try await recorded.apply(.toolCallUpdate(.init(toolCallId: "t", status: .completed)))
        publish()
        controller.update(source)
        for width in [500.0, 700, 450, 800] {
            window.setContentSize(NSSize(width: width, height: 500))
            controller.scroll.frame = window.contentLayoutRect
            window.contentView?.layoutSubtreeIfNeeded()
        }
        // A replaced cell once left AppKit width constraints behind, which threw during this resize.
        let row = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        #expect(labels(in: row).contains("Completed"))
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

/// Records answers instead of sending them to a session controller.
private final class ChoiceRecorder: TranscriptSource {
    let live = LiveTranscriptSource()
    var choices: [(row: Int, option: Int)] = []
    var revision: Int { live.revision }
    var messageCount: Int { live.messageCount }
    func message(at row: Int) -> TranscriptMessage { live.message(at: row) }
    func isStreaming(at row: Int) -> Bool { live.isStreaming(at: row) }
    func toggleExpansion(at row: Int) { live.toggleExpansion(at: row) }
    func choosePermission(at row: Int, option: Int) { choices.append((row, option)) }
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
