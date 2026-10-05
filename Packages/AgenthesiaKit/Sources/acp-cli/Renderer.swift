import ACP
import Foundation

/// Turns session updates into terminal text. Pure: it returns what to print and tracks only what it needs
/// to lay out streamed text.
struct Renderer {
    enum Style {
        case plain
        case ansi
    }

    private enum Mode {
        case idle
        case message
        case thought
    }

    let style: Style
    private var mode = Mode.idle
    private var toolTitles: [String: String] = [:]

    init(style: Style) {
        self.style = style
    }

    /// The title of a tool call seen earlier.
    func title(of toolCallId: String) -> String? {
        toolTitles[toolCallId]
    }

    mutating func render(_ update: ACP.SessionUpdate) -> String {
        switch update {
        case .agentMessageChunk(let chunk):
            let prefix = mode == .message ? "" : lineBreak()
            mode = .message
            return prefix + text(of: chunk.content)
        case .agentThoughtChunk(let chunk):
            let prefix = mode == .thought ? "" : lineBreak() + dim("› ")
            mode = .thought
            return prefix + dim(text(of: chunk.content))
        case .userMessageChunk(let chunk):
            return lineBreak() + bold("> ") + text(of: chunk.content) + "\n"
        case .toolCall(let call):
            toolTitles[call.toolCallId] = call.title
            let details = [call.kind?.rawValue, call.status.map(statusName)].compactMap(\.self)
            let suffix = details.isEmpty ? "" : dim(" · " + details.joined(separator: " · "))
            return lineBreak() + "⏺ " + bold(call.title) + suffix + "\n" + contents(call.content)
        case .toolCallUpdate(let update):
            if let title = update.title {
                toolTitles[update.toolCallId] = title
            }
            guard update.status != nil || update.content?.isEmpty == false else { return "" }
            var output = lineBreak()
            if let status = update.status {
                let title = toolTitles[update.toolCallId] ?? update.toolCallId
                output += "  ⎿ " + title + " " + statusName(status) + "\n"
            }
            return output + contents(update.content)
        case .plan(let plan):
            let entries = plan.entries.map { entry in
                let box =
                    switch entry.status {
                    case .completed: "[x]"
                    case .inProgress: "[~]"
                    default: "[ ]"
                    }
                return "  \(box) \(entry.content)"
            }
            return lineBreak() + bold("Plan") + "\n" + entries.map { $0 + "\n" }.joined()
        case .availableCommands(let update):
            let names = update.availableCommands.map { "/" + $0.name }.joined(separator: " ")
            return lineBreak() + dim("Commands: " + names) + "\n"
        case .configOptions(let update):
            return lineBreak() + dim("Options: " + Self.describe(update.configOptions)) + "\n"
        case .currentMode(let update):
            return lineBreak() + dim("Mode: " + update.currentModeId) + "\n"
        case .sessionInfo(let update):
            guard let title = update.title else { return "" }
            return lineBreak() + dim("Title: " + title) + "\n"
        case .usage(let usage):
            return lineBreak() + dim(Self.describe(usage)) + "\n"
        case .unknown(let raw):
            let kind = raw["sessionUpdate"]?.stringValue ?? "?"
            return lineBreak() + dim("(unsupported update \(kind))") + "\n"
        }
    }

    /// Ends the current turn.
    mutating func endTurn(_ reason: ACP.StopReason) -> String {
        lineBreak() + dim("— " + Self.describe(reason)) + "\n"
    }

    /// Starts a new line if streamed text is open.
    mutating func lineBreak() -> String {
        defer { mode = .idle }
        return mode == .idle ? "" : "\n"
    }

    // MARK: - Pieces

    private func contents(_ contents: [ACP.ToolCallContent]?) -> String {
        (contents ?? []).map { content -> String in
            switch content {
            case .content(let block):
                let body = text(of: block.content).trimmingCharacters(in: .newlines)
                let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
                let shown = lines.prefix(3).map { "    " + dim(String($0)) + "\n" }.joined()
                return lines.count > 3 ? shown + "    " + dim("… \(lines.count - 3) more lines") + "\n" : shown
            case .diff(let diff):
                let (added, removed) = Self.lineChanges(from: diff.oldText ?? "", to: diff.newText)
                return "    ✎ \(diff.path) " + dim("(+\(added) −\(removed))") + "\n"
            case .terminal(let terminal):
                return "    ▸ " + dim("terminal \(terminal.terminalId)") + "\n"
            case .unknown:
                return "    " + dim("(unsupported content)") + "\n"
            }
        }.joined()
    }

    private func text(of block: ACP.ContentBlock) -> String {
        switch block {
        case .text(let content): content.text
        case .image(let image): "[image \(image.mimeType)]"
        case .audio(let audio): "[audio \(audio.mimeType)]"
        case .resourceLink(let link): "[\(link.name)](\(link.uri))"
        case .resource(let resource):
            switch resource.resource {
            case .text(let contents): contents.text
            case .blob(let contents): "[\(contents.uri)]"
            case .unknown: "[resource]"
            }
        case .unknown: "[unsupported content]"
        }
    }

    private func statusName(_ status: ACP.ToolCallStatus) -> String {
        switch status {
        case .pending: "pending"
        case .inProgress: "running"
        case .completed: "done"
        case .failed: "failed"
        case .unknown(let value): value
        }
    }

    static func describe(_ reason: ACP.StopReason) -> String {
        switch reason {
        case .endTurn: "done"
        case .maxTokens: "stopped: token limit"
        case .maxTurnRequests: "stopped: request limit"
        case .refusal: "refused"
        case .cancelled: "cancelled"
        case .unknown(let value): "stopped: \(value)"
        }
    }

    static func describe(_ options: [ACP.ConfigOption]) -> String {
        options.map { option -> String in
            switch option.value {
            case .select(let current, let choices):
                let name = choices.allOptions.first { $0.value == current }?.name ?? current
                return "\(option.name)=\(name)"
            case .boolean(let current):
                return "\(option.name)=\(current ? "on" : "off")"
            case .unknown(let type, _):
                return "\(option.name)=(\(type))"
            }
        }.joined(separator: ", ")
    }

    static func describe(_ usage: ACP.UsageUpdate) -> String {
        let percent = usage.size > 0 ? Int((Double(usage.used) / Double(usage.size) * 100).rounded()) : 0
        var text = "Context: \(tokens(usage.used)) / \(tokens(usage.size)) tokens (\(percent)%)"
        if let cost = usage.cost {
            text += String(format: " · %.2f %@", cost.amount, cost.currency)
        }
        return text
    }

    static func tokens(_ count: Int) -> String {
        guard count >= 1000 else { return String(count) }
        let thousands = String(format: "%.1f", Double(count) / 1000)
        return (thousands.hasSuffix(".0") ? String(thousands.dropLast(2)) : thousands) + "k"
    }

    /// Lines added and removed between two texts.
    static func lineChanges(from old: String, to new: String) -> (added: Int, removed: Int) {
        let oldLines = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false)
        let difference = newLines.difference(from: oldLines)
        return (difference.insertions.count, difference.removals.count)
    }

    // MARK: - Styling

    private func dim(_ text: String) -> String { styled(text, "2") }
    private func bold(_ text: String) -> String { styled(text, "1") }

    private func styled(_ text: String, _ code: String) -> String {
        guard style == .ansi, !text.isEmpty else { return text }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }
}
