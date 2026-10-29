public import Foundation

/// Titles of sessions that the agent has not named (ADR-0039).
public enum SessionTitle {
    public static let maxLength = 80

    /// The first non-blank line, trimmed, at most 80 characters: longer lines are cut at the last word boundary
    /// with an ellipsis, a single longer word at 79 characters plus the ellipsis. Nil for blank text.
    public static func fromPrompt(_ text: String) -> String? {
        guard
            let line = text.split(whereSeparator: \.isNewline).lazy
                .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        guard line.count > maxLength else { return line }
        let head = line.prefix(maxLength - 1)
        var cut = head
        // A space right after `head` means the last word is whole; otherwise drop its remainder.
        if line[head.endIndex] != " ", let space = head.lastIndex(of: " ") { cut = head[..<space] }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}
