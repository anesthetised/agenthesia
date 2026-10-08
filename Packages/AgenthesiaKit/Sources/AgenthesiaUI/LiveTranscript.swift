import ACP
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
    var tool: ToolCardHeader?
}

/// The native part of a tool row; its body remains Markdown so selection and copying work as for messages.
struct ToolCardHeader: Equatable {
    enum Tone: Equatable { case neutral, running, success, failure }
    var symbol: String
    var kind: String
    var status: String
    var tone: Tone
    /// The body exceeds its collapsed bound.
    var expandable = false
    var expanded = false
    /// Titles of the options a pending permission request offers, in the agent's order.
    var actions: [String] = []
    /// Whether ⌥⌘1… choose `actions`; only the oldest pending request has shortcuts.
    var shortcuts = false
}

protocol TranscriptSource: AnyObject {
    var revision: Int { get }
    var messageCount: Int { get }
    func message(at row: Int) -> TranscriptMessage
    func isStreaming(at row: Int) -> Bool
    func toggleExpansion(at row: Int)
    func choosePermission(at row: Int, option: Int)
}

extension TranscriptSource {
    func toggleExpansion(at row: Int) {}
    func choosePermission(at row: Int, option: Int) {}
}

/// Attributed text is cached only for rows requested by NSTableView.
final class LiveTranscriptSource: TranscriptSource {
    var state = TranscriptState()
    var running = false
    var revision = 0
    /// Answers go to the controller, which owns the request's lifetime.
    weak var controller: SessionController?
    var pending: [UUID] = []
    private struct Cached {
        var markdown: String
        var text: NSAttributedString
        var stream: StreamingMarkdown
    }
    private var cache: [Int64: Cached] = [:]
    /// Keyed by row identity, so streamed updates and replay keep a card's expansion.
    private var expanded: Set<Int64> = []
    var messageCount: Int { state.items.count }

    func update(_ controller: SessionController) {
        self.controller = controller
        state = controller.transcript
        pending = controller.pendingPermissions.map(\.id)
        running = controller.status == .running || controller.status == .stopping
        revision += 1
    }

    func isStreaming(at row: Int) -> Bool {
        guard let message = state.items[row].message else { return false }
        return running && message.role != .user && message.turnID == state.activeTurn
    }

    func message(at row: Int) -> TranscriptMessage {
        let item = state.items[row]
        if let tool = item.toolCall {
            let card = Self.toolCard(tool, expanded: expanded.contains(item.id))
            var message = render(id: item.id, role: "Tool", markdown: card.markdown)
            message.tool = card.header
            return message
        }
        if let permission = item.permission {
            let phase: PermissionPhase =
                if let id = permission.requestID, let index = pending.firstIndex(of: id) {
                    .choosing(shortcuts: index == 0)
                } else if running {
                    .recording
                } else {
                    .ended
                }
            let card = Self.permissionCard(permission, phase: phase, expanded: expanded.contains(item.id))
            var message = render(id: item.id, role: "Permission", markdown: card.markdown)
            message.tool = card.header
            return message
        }
        let (role, markdown) = Self.content(item)
        return render(id: item.id, role: role, markdown: markdown)
    }

    func toggleExpansion(at row: Int) {
        let id = state.items[row].id
        if expanded.remove(id) == nil { expanded.insert(id) }
        revision += 1
    }

    func choosePermission(at row: Int, option: Int) {
        guard let permission = state.items[row].permission, let id = permission.requestID,
            permission.options.indices.contains(option)
        else { return }
        controller?.answerPermission(id, with: permission.options[option].optionId)
    }

    func render(id: Int64, role: String, markdown: String) -> TranscriptMessage {
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
        cached.markdown = markdown
        cached.text = text
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
            return ("Tool", toolCard(tool, expanded: false).markdown)
        }
        if let permission = item.permission {
            return ("Permission", permissionCard(permission, phase: .ended, expanded: false).markdown)
        }
        return ("Session", item.notice ?? "")
    }

    static func placeholder(_ block: ACP.ContentBlock) -> String {
        switch block {
        case .text(let text): text.text
        case .image: "[Image attachment]"
        case .audio: "[Audio attachment]"
        case .resourceLink, .resource: "[Resource attachment]"
        case .unknown: "[Unsupported content]"
        }
    }

    static let collapsedLines = 12
    static let collapsedCharacters = 2_000

    /// Shows only what the agent reported. Specialized diff and terminal views are #20 and #31.
    static func toolCard(_ tool: ACP.ToolCall, expanded: Bool) -> (header: ToolCardHeader, markdown: String) {
        let (symbol, kind) = kind(tool.kind)
        let (status, tone) = status(tool.status)
        var header = ToolCardHeader(symbol: symbol, kind: kind, status: status, tone: tone)
        var sections = [title(tool)]
        if let body = body(tool, header: &header, expanded: expanded) { sections.append(body) }
        return (header, sections.joined(separator: "\n\n"))
    }

    enum PermissionPhase: Equatable {
        /// The request awaits the user's choice.
        case choosing(shortcuts: Bool)
        /// The answer is being committed before it reaches the agent.
        case recording
        /// The session ended; no answer can be given any more.
        case ended
    }

    /// States only the recorded response, never an inferred approval or decline.
    static func permissionCard(
        _ permission: TranscriptState.Permission,
        phase: PermissionPhase,
        expanded: Bool
    ) -> (header: ToolCardHeader, markdown: String) {
        let tool = permission.toolCall
        var header = ToolCardHeader(symbol: "hand.raised", kind: "Permission", status: "", tone: .neutral)
        var sections = ["\(kind(tool.kind).label) · \(title(tool))"]
        if let body = body(tool, header: &header, expanded: expanded) { sections.append(body) }
        let option = permission.selectedOption
        switch permission.outcome {
        case nil:
            switch phase {
            case .choosing(let shortcuts):
                (header.status, header.tone) = ("Waiting for your answer", .running)
                header.actions = permission.options.map(\.name)
                header.shortcuts = shortcuts
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

    static func title(_ tool: ACP.ToolCall) -> String {
        tool.title.isEmpty ? "_Untitled tool call_" : "**\(tool.title)**"
    }

    /// The reported locations and content, bounded unless expanded.
    static func body(_ tool: ACP.ToolCall, header: inout ToolCardHeader, expanded: Bool) -> String? {
        var details: [String] = []
        if let locations = tool.locations, !locations.isEmpty {
            details.append(locations.map { "- `\($0.path)\($0.line.map { ":\($0)" } ?? "")`" }.joined(separator: "\n"))
        }
        for content in tool.content ?? [] {
            switch content {
            case .content(let block): details.append(placeholder(block.content))
            case .diff(let diff): details.append("[Diff: `\(diff.path)`\(diff.oldText == nil ? ", new file" : "")]")
            case .terminal(let terminal): details.append("[Terminal: `\(terminal.terminalId)`]")
            case .unknown: details.append("[Unsupported content]")
            }
        }
        guard !details.isEmpty else { return nil }
        let body = details.joined(separator: "\n\n")
        let collapsed = collapse(body)
        header.expandable = collapsed != nil
        header.expanded = expanded && collapsed != nil
        return header.expanded ? body : collapsed ?? body
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

    final class Coordinator {
        let table = TranscriptTableController()
        let source = LiveTranscriptSource()
        let frames = SessionFrameDriver()
        weak var session: SessionController?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.table.scroll }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.session !== session {
            coordinator.session = session
            coordinator.frames.start(session: session, in: view)
        }
        coordinator.source.update(session)
        coordinator.table.update(coordinator.source)
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.frames.stop() }
}
