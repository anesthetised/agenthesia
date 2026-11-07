import ACP
import AgentRuntime
import AgenthesiaCore
import AppKit
import Rendering
import SwiftUI

struct TranscriptMessage {
    let role: String
    var markdown: String
    var text: NSAttributedString
    var previousMarkdown: String?
    var update: StreamingMarkdown.Update?
    /// The signature of inline code links; nil for rows that do not link inline code.
    var links: Int?
    var tool: ToolCardHeader?
    var input: InputCard?
    /// A session notice: a centered caption between hairlines, without role label or Copy.
    var isNotice = false
    var kind = Kind.card
    /// Right-aligned under a user bubble: `not sent` or `sent together`.
    var caption: String?
    /// What Copy returns instead of `markdown`, built only when asked: a folded group's tool cards.
    var copyText: (() -> String)?

    /// How a row presents its role: users get a bubble, agent text no label, thoughts a `Thinking` caption,
    /// a group of tool calls, or a folded permission record, only a header.
    enum Kind: Equatable { case card, user, agent, thought, group }
}

/// The native part of a tool row; its body remains Markdown so selection and copying work as for messages.
struct ToolCardHeader: Equatable {
    enum Tone: Equatable { case neutral, running, attention, success, failure }
    var symbol: String
    var kind: String
    var status: String
    var tone: Tone
    /// The body exceeds its collapsed bound.
    var expandable = false
    var expanded = false
    /// The disclosure reads Details instead of Show all.
    var detailsDisclosure = false
    /// A permission request's one-line record: the status leads and `kind` is the summary after it, truncated.
    var record = false
}

protocol TranscriptSource: AnyObject {
    var revision: Int { get }
    var messageCount: Int { get }
    /// The rows by identity, so that the table inserts and removes only those that changed.
    var rows: [TranscriptRow] { get }
    func message(at row: Int) -> TranscriptMessage
    func isStreaming(at row: Int) -> Bool
    func toggleExpansion(at row: Int)
    /// How many card rows follow the summary at `row` while it is expanded.
    func cardCount(ofGroupAt row: Int) -> Int
}

extension TranscriptSource {
    var rows: [TranscriptRow] { (0..<messageCount).map(TranscriptRow.item) }
    func toggleExpansion(at row: Int) {}
    func cardCount(ofGroupAt row: Int) -> Int { 0 }
}

/// Attributed text is cached only for rows requested by NSTableView.
final class LiveTranscriptSource: TranscriptSource {
    var state = TranscriptState() { didSet { fold() } }
    private(set) var rows: [TranscriptRow] = []
    var running = false
    var revision = 0
    /// Answers go to the controller, which owns the request's lifetime.
    weak var controller: SessionController?
    /// The session's working directory, against which tool call paths link.
    var root: URL?
    /// The displayed session's file index, against which inline code in agent text links.
    var pathIndex = TranscriptPathIndex()
    /// The requests the docked card answers, oldest first.
    var pending: [SessionController.PendingPermission] = [] {
        didSet { pendingCalls = Set(pending.map(\.toolCall.toolCallId)) }
    }
    /// The calls whose tool row leaves its diff to the docked card.
    private var pendingCalls: Set<ACP.ToolCallID> = []
    private struct Cached {
        var markdown: String
        var text: NSAttributedString
        var stream: StreamingMarkdown
        /// `text` with inline code linked against the index of `revision`.
        var linked: (revision: Int, text: NSAttributedString, signature: Int)?
    }
    private var cache: [Int64: Cached] = [:]
    /// Rows are rebuilt on every update; a diff is computed once per edit.
    private var diffs: [ACP.Diff: String] = [:]
    private func cachedDiff(_ diff: ACP.Diff) -> String {
        if let markdown = diffs[diff] { return markdown }
        let markdown = Self.diff(diff)
        diffs[diff] = markdown
        return markdown
    }
    /// Keyed by row identity, so streamed updates and replay keep a card's expansion.
    private var inputDrafts: [UUID: InputDraft] = [:]
    private var expanded: Set<Int64> = []
    /// Keyed by the group's first item, so that a growing group keeps its expansion.
    private var expandedGroups: Set<Int64> = [] { didSet { fold() } }
    var messageCount: Int { rows.count }

    private func fold() {
        let items = state.items
        rows = TranscriptRow.fold(
            count: items.count,
            isToolCall: { items[$0].toolCall != nil },
            isExpanded: { expandedGroups.contains(items[$0].id) }
        )
    }

    func update(_ controller: SessionController) {
        self.controller = controller
        root = URL(filePath: controller.session.workingDirectory)
        state = controller.transcript
        inputDrafts = inputDrafts.filter { id, _ in controller.pendingInputs.contains { $0.id == id } }
        pending = controller.pendingPermissions
        running = controller.status == .running || controller.status == .stopping
        revision += 1
    }

    func isStreaming(at row: Int) -> Bool {
        guard case .item(let index) = rows[row] else { return false }
        return isStreaming(item: index)
    }

    private func isStreaming(item index: Int) -> Bool {
        guard let message = state.items[index].message else { return false }
        return running && message.role != .user && message.turnID == state.activeTurn
    }

    func message(at row: Int) -> TranscriptMessage {
        switch rows[row] {
        case .item(let index): message(item: index)
        case .group(let first): groupMessage(first: first)
        }
    }

    private func groupItems(first: Int) -> ArraySlice<TranscriptState.Item> {
        let items = state.items
        let end = TranscriptRow.groupEnd(from: first, count: items.count) { items[$0].toolCall != nil }
        return items[first..<end]
    }

    private func groupMessage(first: Int) -> TranscriptMessage {
        TranscriptMessage(
            group: groupItems(first: first).compactMap(\.toolCall),
            running: running,
            expanded: expandedGroups.contains(state.items[first].id)
        ) { [weak self] in self?.groupMarkdown(first: first) ?? "" }
    }

    /// The Markdown of a group's cards, as each card's Copy returns it.
    private func groupMarkdown(first: Int) -> String {
        groupItems(first: first).indices.map(fullToolMarkdown).joined(separator: "\n\n")
    }

    /// A card with all its output, whether or not it is collapsed on screen.
    private func fullToolMarkdown(_ index: Int) -> String {
        let item = state.items[index]
        guard let tool = item.toolCall else { return "" }
        return Self.toolCard(tool, output: item.commandOutput, expanded: true, diff: cachedDiff).markdown
    }

    private func permissionPhase(_ permission: TranscriptState.Permission) -> PermissionPhase {
        if let id = permission.requestID, pending.contains(where: { $0.id == id }) {
            .choosing
        } else if running {
            .recording
        } else {
            .ended
        }
    }

    /// A record with its details, whether or not it is folded on screen.
    private func fullPermissionMarkdown(_ index: Int) -> String {
        guard let permission = state.items[index].permission else { return "" }
        return Self.permissionCard(permission, phase: permissionPhase(permission), expanded: true, diff: cachedDiff)
            .markdown
    }

    private func message(item index: Int) -> TranscriptMessage {
        let item = state.items[index]
        if let input = item.input, case .form(let schema) = input.request.mode {
            let active = controller?.pendingInputs.contains { $0.id == input.requestID } == true
            let draft = inputDrafts[input.requestID] ?? InputDraft(schema: schema)
            if active { inputDrafts[input.requestID] = draft } else { inputDrafts.removeValue(forKey: input.requestID) }
            var message = render(id: item.id, role: "Input", markdown: input.request.message)
            let recording =
                !active && input.response == nil
                && (controller?.status == .running || controller?.status == .idle || controller?.status == .stopping)
            message.input = InputCard(input: input, active: active, recording: recording, draft: draft) {
                [weak controller] response in
                controller?.answerInput(input.requestID, with: response)
            }
            return message
        }
        if let tool = item.toolCall {
            let card = Self.toolCard(
                tool,
                output: item.commandOutput,
                expanded: expanded.contains(item.id),
                hidingDiffs: pendingCalls.contains(tool.toolCallId),
                diff: cachedDiff
            )
            var message = render(id: item.id, role: "Tool", markdown: card.markdown, links: links(tool))
            message.tool = card.header
            message.copyText = { [weak self] in self?.fullToolMarkdown(index) ?? "" }
            return message
        }
        if let permission = item.permission {
            let isExpanded = expanded.contains(item.id)
            let card = Self.permissionCard(
                permission,
                phase: permissionPhase(permission),
                expanded: isExpanded,
                diff: cachedDiff
            )
            // Folded, a record is only its header, as a group is; Details shows the call.
            var message =
                isExpanded
                ? render(id: item.id, role: "Permission", markdown: card.markdown, links: links(permission.toolCall))
                : TranscriptMessage(role: "Permission", markdown: "", text: NSAttributedString(string: ""))
            message.tool = card.header
            if !isExpanded { message.kind = .group }
            message.copyText = { [weak self] in self?.fullPermissionMarkdown(index) ?? "" }
            return message
        }
        if item.isFailure, let stored = item.notice {
            let summary = PromptFailure.summary(stored)
            let hasDetails = summary != stored
            let isExpanded = hasDetails && expanded.contains(item.id)
            var message = render(
                id: item.id,
                role: "Error",
                markdown: isExpanded ? summary + "\n\n```\n" + stored + "\n```" : summary
            )
            message.tool = ToolCardHeader(
                symbol: "exclamationmark.triangle",
                kind: "Prompt failed",
                status: "",
                tone: .failure,
                expandable: hasDetails,
                expanded: isExpanded,
                detailsDisclosure: true
            )
            return message
        }
        let (role, markdown) = Self.content(item)
        // Streaming rows keep their text until they finish; user prompts never link.
        let linksInlineCode = item.message.map { $0.role != .user } == true && !isStreaming(item: index)
        var message = render(id: item.id, role: role, markdown: markdown, linksInlineCode: linksInlineCode)
        message.isNotice = item.message == nil
        if let source = item.message {
            switch source.role {
            case .user:
                message.kind = .user
                message.caption = source.notSent ? "not sent" : source.sentTogether ? "sent together" : nil
            case .assistant: message.kind = .agent
            case .thought: message.kind = .thought
            }
        }
        return message
    }

    /// Makes the item's row exist and its whole text visible, expanding what hides it. Returns its row.
    func reveal(item index: Int) -> Int? {
        let items = state.items
        guard items.indices.contains(index) else { return nil }
        if items[index].toolCall != nil {
            var first = index
            while first > 0, items[first - 1].toolCall != nil { first -= 1 }
            if groupItems(first: first).count > 1 { expandedGroups.insert(items[first].id) }
        }
        expanded.insert(items[index].id)
        revision += 1
        return rows.firstIndex(of: .item(index))
    }

    func cardCount(ofGroupAt row: Int) -> Int {
        guard case .group(let first) = rows[row], expandedGroups.contains(state.items[first].id) else { return 0 }
        return groupItems(first: first).count
    }

    func toggleExpansion(at row: Int) {
        switch rows[row] {
        case .item(let index):
            let id = state.items[index].id
            if expanded.remove(id) == nil { expanded.insert(id) }
        case .group(let first):
            let id = state.items[first].id
            if expandedGroups.remove(id) == nil { expandedGroups.insert(id) }
        }
        revision += 1
    }

    private func links(_ tool: ACP.ToolCall) -> [(display: String, link: PathLink)] {
        root.map { PathLink.targets(of: tool, root: $0) } ?? []
    }

    /// `links` mark the inline code that shows a path; they are not part of the Markdown that Copy returns. They are
    /// resolved, against the file system, only when the row's text changed. `linksInlineCode` links inline code
    /// against `pathIndex` once per index revision.
    func render(
        id: Int64,
        role: String,
        markdown: String,
        links: @autoclosure () -> [(display: String, link: PathLink)] = [],
        linksInlineCode: Bool = false
    ) -> TranscriptMessage {
        var message = renderMarkdown(id: id, role: role, markdown: markdown, links: links())
        guard linksInlineCode, var cached = cache[id] else { return message }
        let linked: (revision: Int, text: NSAttributedString, signature: Int)
        if let current = cached.linked, current.revision == pathIndex.revision {
            linked = current
        } else {
            let result = pathIndex.linkingInlineCode(in: cached.text)
            linked = (pathIndex.revision, result.text, result.signature)
            cached.linked = linked
            cache[id] = cached
        }
        message.text = linked.text
        message.links = linked.signature
        return message
    }

    private func renderMarkdown(
        id: Int64,
        role: String,
        markdown: String,
        links: @autoclosure () -> [(display: String, link: PathLink)]
    ) -> TranscriptMessage {
        if let cached = cache[id], cached.markdown == markdown {
            return TranscriptMessage(role: role, markdown: markdown, text: cached.text)
        }
        var cached =
            cache[id] ?? Cached(markdown: "", text: NSAttributedString(string: ""), stream: StreamingMarkdown())
        let previous = cached.markdown
        let update: StreamingMarkdown.Update
        if markdown.hasPrefix(previous) {
            update = cached.stream.append(String(markdown.dropFirst(previous.count)))
        } else {
            cached = Cached(markdown: "", text: NSAttributedString(string: ""), stream: StreamingMarkdown())
            update = cached.stream.append(markdown)
        }
        let text = NSMutableAttributedString(attributedString: cached.text)
        update.apply(to: text)
        PathLink.apply(links(), to: text)
        cached.markdown = markdown
        cached.text = text
        cached.linked = nil
        cache[id] = cached
        return TranscriptMessage(
            role: role,
            markdown: markdown,
            text: text,
            previousMarkdown: markdown.hasPrefix(previous) ? previous : nil,
            update: update
        )
    }

    static func content(_ item: TranscriptState.Item) -> (String, String) {
        if let message = item.message {
            let role: String =
                switch message.role {
                case .user: "You";
                case .assistant: "Agent";
                case .thought: "Thinking"
                }
            let text = message.content.map { block -> String in
                if case .text(let text) = block { return text.text }
                return "\n\n\(placeholder(block))\n\n"
            }.joined()
            return (role, text)
        }
        if let tool = item.toolCall {
            return ("Tool", toolCard(tool, output: item.commandOutput, expanded: false).markdown)
        }
        if let permission = item.permission {
            return ("Permission", permissionCard(permission, phase: .ended, expanded: false).markdown)
        }
        if let input = item.input {
            return ("Input", input.request.message + "\n\n" + InputForm.outcome(input.response))
        }
        if let date = item.reopenedAt {
            return ("Session", "Continued · \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        return ("Session", item.notice ?? "")
    }

    static func placeholder(_ block: ACP.ContentBlock) -> String {
        switch block {
        case .text(let text): text.text
        case .image: "[Image attachment]"
        case .audio: "[Audio attachment]"
        case .resourceLink(let link): "[Attachment: `\(link.title ?? link.name)`]"
        case .resource: "[Resource attachment]"
        case .unknown: "[Unsupported content]"
        }
    }

    static let collapsedLines = 12
    static let collapsedCharacters = 2_000

    /// Shows only what the agent reported.
    static func toolCard(
        _ tool: ACP.ToolCall,
        output: TranscriptState.CommandOutput? = nil,
        expanded: Bool,
        hidingDiffs: Bool = false,
        diff: (ACP.Diff) -> String = diff
    ) -> (header: ToolCardHeader, markdown: String) {
        let (symbol, kind) = kind(tool.kind)
        let (status, tone) = status(tool.status)
        var header = ToolCardHeader(symbol: symbol, kind: kind, status: status, tone: tone)
        var sections = [title(tool)]
        if let body = body(
            tool,
            output: output,
            header: &header,
            expanded: expanded,
            hidingDiffs: hidingDiffs,
            diff: diff
        ) {
            sections.append(body)
        }
        return (header, sections.joined(separator: "\n\n"))
    }

    enum PermissionPhase: Equatable {
        /// The request awaits the user's choice, on the docked card.
        case choosing
        /// The answer is being committed before it reaches the agent.
        case recording
        /// The session ended; no answer can be given any more.
        case ended
    }

    /// The record of a request: a header that reads `Allowed once · Edit · Write note.txt`, and the call with its
    /// outcome as its details. States only the recorded response, never an inferred approval or decline.
    static func permissionCard(
        _ permission: TranscriptState.Permission,
        phase: PermissionPhase,
        expanded: Bool,
        diff: (ACP.Diff) -> String = diff
    ) -> (header: ToolCardHeader, markdown: String) {
        let tool = permission.toolCall
        var header = ToolCardHeader(
            symbol: "hand.raised",
            kind: "· \(kind(tool.kind).label)\(summary(of: tool).map { " · \($0)" } ?? "")",
            status: "",
            tone: .neutral,
            detailsDisclosure: true,
            record: true
        )
        var sections = ["\(kind(tool.kind).label) · \(title(tool))"]
        if let body = body(tool, header: &header, expanded: expanded, diff: diff) { sections.append(body) }
        // Details always has the call and the outcome to show; `body` judged only the bound of its own text.
        (header.expandable, header.expanded) = (true, expanded)
        let option = permission.selectedOption
        switch permission.outcome {
        case nil:
            switch phase {
            case .choosing:
                (header.status, header.tone) = ("Waiting for you", .attention)
                var prompt = "The agent asks for permission to run this tool."
                if permission.options.contains(where: { $0.kind == .allowAlways || $0.kind == .rejectAlways }) {
                    prompt += " “Always” choices are remembered by the agent, not by Agenthesia."
                }
                sections.append(prompt)
            case .recording:
                header.status = "Recording answer"
                sections.append("Recording the answer before it is sent to the agent…")
            case .ended:
                header.status = "No answer"
                sections.append("No answer was recorded before the session ended.")
            }
        case .cancelled:
            header.status = "Cancelled"
            sections.append("Request cancelled; no option was returned to the agent.")
        case .selected(let id):
            guard let option else {
                header.status = "Answered"
                sections.append("Answered with option “\(id)”.")
                break
            }
            (header.status, header.tone) =
                switch option.kind {
                case .allowOnce: ("Allowed once", .success)
                case .allowAlways: ("Always allowed", .success)
                case .rejectOnce: ("Rejected once", .failure)
                case .rejectAlways: ("Always rejected", .failure)
                case .unknown: ("Answered", .neutral)
                }
            let remembered = option.kind == .allowAlways || option.kind == .rejectAlways
            sections.append(
                "Returned “\(option.name)” to the agent."
                    + (remembered ? " The agent may apply it to later requests." : "")
            )
        case .unknown:
            header.status = "Unknown outcome"
            sections.append("Unrecognized permission outcome.")
        }
        return (header, sections.joined(separator: "\n\n"))
    }

    /// The first line of the title, without code marks, for a one-line record; `nil` when there is none.
    static func summary(of tool: ACP.ToolCall) -> String? {
        tool.title.split(whereSeparator: \.isNewline).first.map { $0.replacing("`", with: "") }.flatMap {
            $0.isEmpty ? nil : String($0)
        }
    }

    static func title(_ tool: ACP.ToolCall) -> String {
        tool.title.isEmpty ? "_Untitled tool call_" : "**\(tool.title)**"
    }

    /// The reported locations, content and command output, bounded unless expanded.
    static func body(
        _ tool: ACP.ToolCall,
        output: TranscriptState.CommandOutput? = nil,
        header: inout ToolCardHeader,
        expanded: Bool,
        hidingDiffs: Bool = false,
        diff: (ACP.Diff) -> String = diff
    ) -> String? {
        var details: [String] = []
        if let locations = tool.locations, !locations.isEmpty {
            details.append(locations.map { "- `\($0.path)\($0.line.map { ":\($0)" } ?? "")`" }.joined(separator: "\n"))
        }
        for content in tool.content ?? [] {
            switch content {
            case .content(let block): details.append(placeholder(block.content))
            case .diff(let edit): if !hidingDiffs { details.append(diff(edit)) }
            case .terminal(let terminal):
                if output == nil { details.append("[Terminal: `\(terminal.terminalId)`]") }
            case .unknown: details.append("[Unsupported content]")
            }
        }
        let body = details.joined(separator: "\n\n")
        let collapsed = details.isEmpty ? nil : collapse(body)
        let command = output.flatMap { commandOutput($0, expanded: expanded) }
        header.expandable = collapsed != nil || command?.oversized == true
        header.expanded = expanded && header.expandable
        let shown = details.isEmpty ? nil : header.expanded ? body : collapsed ?? body
        let sections = [shown, command?.markdown].compactMap { $0 }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// The output as a code block, showing only the last lines unless expanded, with the exit status.
    /// `oversized` tells that the output exceeds the collapsed bound.
    static func commandOutput(
        _ command: TranscriptState.CommandOutput,
        expanded: Bool
    ) -> (markdown: String, oversized: Bool)? {
        let text = TerminalText.make(from: command.output, byteLimit: TranscriptState.CommandOutput.byteLimit)
        var lines = text.text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        var shown = lines.joined(separator: "\n")
        let oversized = lines.count > collapsedLines || shown.count > collapsedCharacters
        let cut = oversized && !expanded
        if cut {
            shown = String(lines.suffix(collapsedLines).joined(separator: "\n").suffix(collapsedCharacters))
        }
        var sections: [String] = []
        let hidden = lines.count - shown.split(separator: "\n", omittingEmptySubsequences: false).count
        if cut {
            sections.append(hidden > 0 ? "_… \(hidden) earlier line\(hidden == 1 ? "" : "s")_" : "_… truncated_")
        } else if text.truncated {
            sections.append("_… earlier output dropped_")
        }
        if !shown.isEmpty { sections.append(fenced(shown)) }
        if let exit = command.exit {
            let status: String =
                switch (exit.exitCode, exit.signal) {
                case (_, let signal?): "Terminated by signal \(signal)"
                case (let code?, nil): "Exit code \(code)"
                case (nil, nil): "Exited"
                }
            sections.append(status)
        }
        return sections.isEmpty ? nil : (sections.joined(separator: "\n\n"), oversized)
    }

    /// `code` as a fenced block, the fence longer than any backtick run in `code` so it cannot close the fence.
    nonisolated static func fenced(_ code: String, language: String = "") -> String {
        var longest = 0
        var run = 0
        for character in code {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(code)\n\(fence)"
    }

    /// The edited path and its unified diff.
    nonisolated static func diff(_ diff: ACP.Diff) -> String {
        let path = "`\(diff.path)`\(diff.oldText == nil ? " (new file)" : "")"
        let hunks = UnifiedDiff.make(old: diff.oldText, new: diff.newText)
        return hunks.isEmpty ? "\(path): no changes" : "\(path)\n\n\(fenced(hunks, language: "diff"))"
    }

    /// The body bounded to its collapsed size, or `nil` when it already fits.
    static func collapse(_ body: String) -> String? {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > collapsedLines || body.count > collapsedCharacters else { return nil }
        var kept = String(lines.prefix(collapsedLines).joined(separator: "\n").prefix(collapsedCharacters))
        let keptLines = kept.split(separator: "\n", omittingEmptySubsequences: false)
        // Close a fence the cut left open, so the note below is not shown as code.
        if let fence = MarkdownRenderer.closingCodeFence(in: kept) { kept += "\n" + fence }
        let hidden = lines.count - keptLines.count
        return kept + (hidden > 0 ? "\n\n_… \(hidden) more line\(hidden == 1 ? "" : "s")_" : "\n\n_… truncated_")
    }

    static func kind(_ kind: ACP.ToolKind?) -> (symbol: String, label: String) {
        switch kind {
        case .read: ("doc.text", "Read")
        case .edit: ("pencil", "Edit")
        case .delete: ("trash", "Delete")
        case .move: ("arrow.right.doc.on.clipboard", "Move")
        case .search: ("magnifyingglass", "Search")
        case .execute: ("terminal", "Execute")
        case .think: ("brain", "Think")
        case .fetch: ("network", "Fetch")
        case .switchMode: ("arrow.triangle.2.circlepath", "Switch mode")
        case .other: ("wrench.and.screwdriver", "Other")
        case .unknown(let value): ("wrench.and.screwdriver", value)
        case nil: ("wrench.and.screwdriver", "Tool")
        }
    }

    static func status(_ status: ACP.ToolCallStatus?) -> (String, ToolCardHeader.Tone) {
        switch status {
        case .pending: ("Pending", .neutral)
        case .inProgress: ("Running", .running)
        case .completed: ("Completed", .success)
        case .failed: ("Failed", .failure)
        case .unknown(let value): (value, .neutral)
        case nil: ("Status not reported", .neutral)
        }
    }
}

struct LiveTranscript: NSViewRepresentable {
    let session: SessionController
    let pathIndex: TranscriptPathIndex
    var find = TranscriptFindState()
    /// A clicked path link, with the session whose transcript it was in.
    let onOpenPath: (PathLink, UUID) -> Void

    final class Coordinator {
        let table = TranscriptTableController()
        let source = LiveTranscriptSource()
        let frames = SessionFrameDriver()
        weak var session: SessionController?
        var revealed: UUID?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.table.scroll }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.session !== session {
            coordinator.session = session
            let id = session.session.id
            coordinator.table.openPath = { onOpenPath($0, id) }
            coordinator.frames.start(session: session, in: view)
        }
        coordinator.source.pathIndex = pathIndex
        coordinator.source.update(session)
        var row: Int?
        if let reveal = find.reveal, reveal.id != coordinator.revealed {
            coordinator.revealed = reveal.id
            row = coordinator.source.reveal(item: reveal.item)
        }
        coordinator.table.update(coordinator.source)
        coordinator.table.findQuery = find.isOpen ? find.query : ""
        if let row { coordinator.table.reveal(row: row) }
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.frames.stop() }
}
