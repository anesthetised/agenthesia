public import AppKit

/// Unified diffs of file edits, and their highlighting with changed words marked.
public enum UnifiedDiff {
    /// Unchanged lines kept around each change.
    public static let contextLines = 3
    /// Changed runs with more lines than this are not compared word by word.
    // ponytail: a fixed cap keeps huge rewrites cheap; tune with `just bench` if real edits hit it.
    static let wordDiffLineLimit = 200
    /// Edits whose changed lines surely exceed this are shown as a whole replacement: `difference(from:)`
    /// grows with the square of the edit count, about 18 ms at 1,000 lines.
    // ponytail: the bound misses reordered lines; compute off the main thread if such edits stall the transcript.
    static let editLimit = 1_000

    /// The hunks that turn `old` into `new`, without file headers; `nil` is a new file. Empty when nothing changed.
    public static func make(old: String?, new: String) -> String {
        let oldLines = lines(of: old ?? "")
        let newLines = lines(of: new)
        let prefix = zip(oldLines, newLines).prefix { $0 == $1 }.count
        let suffix = zip(oldLines[prefix...].reversed(), newLines[prefix...].reversed()).prefix { $0 == $1 }.count
        let oldChanged = oldLines[prefix..<oldLines.count - suffix]
        let newChanged = newLines[prefix..<newLines.count - suffix]
        var removed = Set<Int>()
        var inserted = Set<Int>()
        if minimumEdits(from: oldChanged, to: newChanged) > editLimit {
            removed = Set(oldChanged.indices)
            inserted = Set(newChanged.indices)
        } else {
            for change in Array(newChanged).difference(from: Array(oldChanged)) {
                switch change {
                case .remove(let offset, _, _): removed.insert(prefix + offset)
                case .insert(let offset, _, _): inserted.insert(prefix + offset)
                }
            }
        }
        // The edit script, with the line before which each entry stands in both files.
        // Within a changed region removals come first, as in `diff -u`.
        var script: [(mark: Character, line: Substring, old: Int, new: Int)] = []
        var (old, new) = (0, 0)
        while old < oldLines.count || new < newLines.count {
            if removed.contains(old) {
                script.append(("-", oldLines[old], old, new))
                old += 1
            } else if inserted.contains(new) {
                script.append(("+", newLines[new], old, new))
                new += 1
            } else {
                script.append((" ", oldLines[old], old, new))
                old += 1
                new += 1
            }
        }
        var output: [String] = []
        var index = 0
        while let first = script[index...].firstIndex(where: { $0.mark != " " }) {
            var last = first
            while let next = script[(last + 1)...].firstIndex(where: { $0.mark != " " }),
                next - last <= 2 * contextLines + 1
            {
                last = next
            }
            let hunk = script[max(first - contextLines, 0)...min(last + contextLines, script.count - 1)]
            let oldCount = hunk.count { $0.mark != "+" }
            let newCount = hunk.count { $0.mark != "-" }
            let start = script[hunk.startIndex]
            // An empty side names the line before it, so a new file reads `-0,0`.
            let oldStart = start.old + (oldCount == 0 ? 0 : 1)
            let newStart = start.new + (newCount == 0 ? 0 : 1)
            output.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            output += hunk.map { "\($0.mark)\($0.line)" }
            index = hunk.endIndex
        }
        return output.joined(separator: "\n")
    }

    /// A lower bound of the removed and inserted lines: those without a counterpart in the other side.
    static func minimumEdits(from old: ArraySlice<Substring>, to new: ArraySlice<Substring>) -> Int {
        var unmatched: [Substring: Int] = [:]
        for line in old { unmatched[line, default: 0] += 1 }
        var shared = 0
        for line in new where unmatched[line, default: 0] > 0 {
            unmatched[line, default: 0] -= 1
            shared += 1
        }
        return old.count + new.count - 2 * shared
    }

    /// The lines of `text`; a final newline does not start another line.
    static func lines(of text: String) -> [Substring] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// `diff` as code: added and removed lines tinted, the words that changed between them tinted stronger.
    public static func highlight(_ diff: String, theme: Theme) -> NSMutableAttributedString {
        let text = NSMutableAttributedString(
            string: diff,
            attributes: [
                .font: theme.codeFont, .foregroundColor: theme.textColor, .backgroundColor: theme.codeBackgroundColor,
            ]
        )
        var removed: [(line: Substring, location: Int)] = []
        var added: [(line: Substring, location: Int)] = []
        func compareWords() {
            if !removed.isEmpty, !added.isEmpty, removed.count + added.count <= wordDiffLineLimit {
                let old = tokens(removed)
                let new = tokens(added)
                for change in new.map(\.text).difference(from: old.map(\.text)) {
                    switch change {
                    case .remove(let offset, _, _):
                        text.addAttribute(
                            .backgroundColor,
                            value: theme.diffRemovedWordColor,
                            range: old[offset].range
                        )
                    case .insert(let offset, _, _):
                        text.addAttribute(.backgroundColor, value: theme.diffAddedWordColor, range: new[offset].range)
                    }
                }
            }
            removed = []
            added = []
        }
        var location = 0
        for line in diff.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let range = NSRange(location: location, length: line.utf16.count)
            switch line.first {
            case "-":
                if !added.isEmpty { compareWords() }
                removed.append((line.dropFirst(), location + 1))
                text.addAttribute(.backgroundColor, value: theme.diffRemovedColor, range: range)
            case "+":
                added.append((line.dropFirst(), location + 1))
                text.addAttribute(.backgroundColor, value: theme.diffAddedColor, range: range)
            default:
                compareWords()
                if line.hasPrefix("@@") {
                    text.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: range)
                }
            }
            location = NSMaxRange(range) + 1
        }
        compareWords()
        return text
    }

    /// Words, single other characters and line breaks of `lines`, located in the whole diff.
    private static func tokens(_ lines: [(line: Substring, location: Int)]) -> [(text: Substring, range: NSRange)] {
        var result: [(text: Substring, range: NSRange)] = []
        for (number, (line, start)) in lines.enumerated() {
            if number > 0 { result.append(("\n", NSRange(location: start - 2, length: 0))) }
            var location = start
            var index = line.startIndex
            while index < line.endIndex {
                let isWord = { (character: Character) in character.isLetter || character.isNumber || character == "_" }
                let end =
                    isWord(line[index])
                    ? line[index...].firstIndex { !isWord($0) } ?? line.endIndex : line.index(after: index)
                let token = line[index..<end]
                let length = token.utf16.count
                result.append((token, NSRange(location: location, length: length)))
                location += length
                index = end
            }
        }
        return result
    }
}
