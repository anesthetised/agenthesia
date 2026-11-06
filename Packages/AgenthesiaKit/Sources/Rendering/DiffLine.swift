/// One line of `UnifiedDiff.make` output, with its line numbers in the old and the new file.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case hunk, context, added, removed }

    public var kind: Kind
    /// The line in the old file; `nil` for added lines and hunk headers.
    public var oldNumber: Int?
    /// The line in the new file; `nil` for removed lines and hunk headers.
    public var newNumber: Int?
    /// Where the line stands in the new file: its own number, or for a removed line the line that follows it.
    /// Zero for a hunk header.
    public var newPosition: Int
    /// The line without its `+`, `-` or space mark; the header itself for a hunk.
    public var text: String

    public init(kind: Kind, oldNumber: Int? = nil, newNumber: Int? = nil, newPosition: Int = 0, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.newPosition = newPosition
        self.text = text
    }
}

extension UnifiedDiff {
    /// The lines of `diff`, one per line of text in the same order, so the entry at an index is the text line at that
    /// index. `diff` is `make`'s output; a `\ No newline at end of file` marker is skipped.
    public static func parse(_ diff: String) -> [DiffLine] {
        guard !diff.isEmpty else { return [] }
        var result: [DiffLine] = []
        var old = 0
        var new = 0
        for line in diff.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("@@"), let start = hunkStarts(line) {
                (old, new) = start
                result.append(DiffLine(kind: .hunk, text: String(line)))
                continue
            }
            switch line.first {
            case "-":
                result.append(
                    DiffLine(kind: .removed, oldNumber: old, newPosition: new, text: String(line.dropFirst()))
                )
                old += 1
            case "+":
                result.append(DiffLine(kind: .added, newNumber: new, newPosition: new, text: String(line.dropFirst())))
                new += 1
            case "\\":
                continue
            default:
                result.append(
                    DiffLine(
                        kind: .context,
                        oldNumber: old,
                        newNumber: new,
                        newPosition: new,
                        text: String(line.dropFirst())
                    )
                )
                old += 1
                new += 1
            }
        }
        return result
    }

    /// The first old and new line of the hunk in a `@@ -a,b +c,d @@` header; an empty side names the line before it.
    private static func hunkStarts(_ header: Substring) -> (old: Int, new: Int)? {
        let fields = header.split(separator: " ")
        guard fields.count >= 3, fields[1].hasPrefix("-"), fields[2].hasPrefix("+") else { return nil }
        func start(_ field: Substring) -> Int? {
            let parts = field.dropFirst().split(separator: ",")
            guard let first = parts.first.flatMap({ Int($0) }) else { return nil }
            return parts.count > 1 && parts[1] == "0" ? first + 1 : first
        }
        guard let old = start(fields[1]), let new = start(fields[2]) else { return nil }
        return (old, new)
    }
}
