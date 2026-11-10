public import ACP
import Foundation
import JSONRPC

/// The command a permission request for a shell call asks to run, so that the surfaces which answer it can show it
/// whole instead of the agent's title, which for some agents is only the tool's name.
public enum PermissionCommand {
    /// Lines the board card shows of a command, and the characters it estimates a line holds. A card cannot tell the
    /// core how it wraps, so a command is cut when it has more lines than this or is longer than they hold.
    public static let boardLines = 4
    static let boardLineWidth = 50

    /// The command of an `execute` call, or `nil` for any other kind, in this order: `rawInput.command` as a string;
    /// as an argument array, joined with shell quoting and without a leading `bash -lc` or `sh -c`; the first text
    /// content; the title. Agents differ in which of these they fill, and some send `rawInput` in a later update.
    public static func of(_ call: ACP.ToolCall) -> String? {
        guard call.kind == .execute else { return nil }
        let candidates: [String?] = [
            call.rawInput?["command"].flatMap(words),
            (call.content ?? []).compactMap { content -> String? in
                if case .content(let block) = content, case .text(let text) = block.content { text.text } else { nil }
            }.first,
            call.title,
        ]
        return candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first {
            !$0.isEmpty
        }
    }

    /// The first line of `command`, for a surface that has room for one: VoiceOver's announcement.
    public static func firstLine(_ command: String) -> String {
        command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
    }

    /// Whether the board card, which shows ``boardLines`` lines, would cut `command`.
    public static func isCutOnBoard(_ command: String) -> Bool {
        let lines = command.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.reduce(0) { $0 + max(1, ($1.count + boardLineWidth - 1) / boardLineWidth) } > boardLines
    }

    private static func words(_ value: JSONValue) -> String? {
        switch value {
        case .string(let string): return string
        case .array(let items):
            var arguments = items.compactMap(\.stringValue)
            guard arguments.count == items.count else { return nil }
            // `["bash", "-lc", script]` is how some agents spawn a command; the script is the command.
            if arguments.count >= 3,
                ["bash", "sh", "zsh"].contains(arguments[0].split(separator: "/").last.map(String.init)),
                arguments[1].hasPrefix("-"), arguments[1].hasSuffix("c")
            {
                arguments.removeFirst(2)
                if arguments.count == 1 { return arguments[0] }
            }
            return arguments.map(quoted).joined(separator: " ")
        default: return nil
        }
    }

    /// `argument` as one shell word: as it is when it needs no quoting, else in single quotes.
    private static func quoted(_ argument: String) -> String {
        let plain = argument.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_@%+=:,./-".contains($0)) }
        if !argument.isEmpty, plain { return argument }
        return "'" + argument.replacing("'", with: "'\\''") + "'"
    }
}
