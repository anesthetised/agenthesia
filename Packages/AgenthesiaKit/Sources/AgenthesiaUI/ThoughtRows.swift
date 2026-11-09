import AgenthesiaCore
import Foundation

/// The header of a row of thoughts (ADR-0039's amendment): what the agent is thinking, or how long it thought.
enum ThoughtSummary {
    /// `thinking` while the thoughts end a running turn's transcript; `latest` is the text of the last of them, whose
    /// last line a collapsed row shows. Expanded, the row shows the text itself below `Thinking…`.
    static func header(latest: String, thinking: Bool, duration: TimeInterval, expanded: Bool) -> ToolCardHeader {
        let line = lastLine(of: latest)
        let kind =
            !thinking
            ? "Thought for \(WorkingDuration.format(duration))"
            : expanded || line.isEmpty ? "Thinking…" : "Thinking… \(line)"
        return ToolCardHeader(
            symbol: "brain",
            kind: kind,
            status: "",
            tone: .neutral,
            expandable: true,
            expanded: expanded
        )
    }

    /// The last line with text, without code and emphasis marks. Reads from the end, so a long thought costs only its
    /// last line on each streamed chunk.
    static func lastLine(of text: String) -> String {
        guard let end = text.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        let start = text[..<end].lastIndex(where: \.isNewline).map(text.index(after:)) ?? text.startIndex
        return text[start...end].replacing("`", with: "").replacing("**", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension LiveTranscriptSource {
    /// A row of thoughts: only a header while collapsed, their Markdown below it once expanded. Copy returns all of
    /// it either way, built only when asked.
    func thoughts(
        id: Int64,
        latest: String,
        thinking: Bool,
        duration: TimeInterval,
        expanded: Bool,
        markdown: @escaping () -> String
    ) -> TranscriptMessage {
        var message =
            expanded
            ? render(id: id, role: "Thinking", markdown: markdown(), linksInlineCode: !thinking)
            : TranscriptMessage(role: "Thinking", markdown: "", text: NSAttributedString(string: ""))
        message.tool = ThoughtSummary.header(latest: latest, thinking: thinking, duration: duration, expanded: expanded)
        message.kind = expanded ? .thought : .group
        message.copyText = markdown
        return message
    }
}
