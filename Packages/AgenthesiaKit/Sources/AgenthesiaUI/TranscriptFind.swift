import ACP
import AgenthesiaCore
import AppKit
import Foundation

/// Find in the transcript: which items match, by item index. It reads each item's full text, so it also finds what a
/// folded group or a collapsed card does not show.
enum TranscriptSearch {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func matches(_ query: String, in items: [TranscriptState.Item]) -> [Int] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return items.indices.filter { fullText(of: items[$0]).range(of: query, options: options) != nil }
    }

    static func failedToolCalls(in items: [TranscriptState.Item]) -> [Int] {
        items.indices.filter { items[$0].toolCall?.status == .failed }
    }

    static func fullText(of item: TranscriptState.Item) -> String {
        if let tool = item.toolCall {
            return LiveTranscriptSource.toolCard(tool, output: item.commandOutput, expanded: true).markdown
        }
        if let permission = item.permission {
            return LiveTranscriptSource.permissionCard(permission, phase: .ended, expanded: true).markdown
        }
        return LiveTranscriptSource.content(item).1
    }

    /// `text` with every occurrence of `query` marked as AppKit marks a find result.
    static func highlighted(_ text: NSAttributedString, query: String) -> NSAttributedString {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return text }
        let marked = NSMutableAttributedString(attributedString: text)
        let string = text.string as NSString
        var searched = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: query, options: options, range: searched)
            guard found.location != NSNotFound, found.length > 0 else { return marked }
            marked.addAttributes(
                [.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black],
                range: found
            )
            searched = NSRange(location: found.upperBound, length: string.length - found.upperBound)
        }
    }
}

/// The window's find bar. Typing only counts and highlights; a step moves to a match and may expand what hides it.
struct TranscriptFindState {
    /// A request to bring an item into view.
    struct Reveal: Equatable {
        let id = UUID()
        let item: Int
    }

    var isOpen = false
    var query = ""
    /// The matching items, as of the last edit or step; a streamed answer does not recount on every chunk.
    var matches: [Int] = []
    var reveal: Reveal?
    var focusRequests = 0

    /// The position of the item last stepped to, while it still matches.
    var current: Int? { reveal.flatMap { matches.firstIndex(of: $0.item) } }

    var status: String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        if matches.isEmpty { return "No matches" }
        if let current { return "\(current + 1) of \(matches.count)" }
        return matches.count == 1 ? "1 match" : "\(matches.count) matches"
    }

    /// The next of `items` after the last reveal, wrapping; the first step lands on the newest.
    func step(in items: [Int], backward: Bool) -> Int? {
        guard let from = reveal?.item else { return items.last }
        return backward
            ? items.last { $0 < from } ?? items.last
            : items.first { $0 > from } ?? items.first
    }
}
