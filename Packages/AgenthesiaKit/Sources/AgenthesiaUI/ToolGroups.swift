import ACP
import Foundation

/// A display row of the transcript, identified by item index; items only append, so an index stays valid.
enum TranscriptRow: Hashable {
    case item(Int)
    /// A summary of two or more consecutive tool calls, the first of them at this item.
    case group(first: Int)

    /// One tool call stays a plain card; any other item, such as a permission request or input form, ends a group.
    /// An expanded group's calls follow its summary as plain cards.
    static func fold(count: Int, isToolCall: (Int) -> Bool, isExpanded: (Int) -> Bool) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(count)
        var index = 0
        while index < count {
            let end = groupEnd(from: index, count: count, isToolCall: isToolCall)
            guard end - index > 1 else {
                rows.append(.item(index))
                index += 1
                continue
            }
            rows.append(.group(first: index))
            if isExpanded(index) { rows += (index..<end).map(TranscriptRow.item) }
            index = end
        }
        return rows
    }

    /// The end of the run of tool calls at `first`.
    static func groupEnd(from first: Int, count: Int, isToolCall: (Int) -> Bool) -> Int {
        var end = first
        while end < count, isToolCall(end) { end += 1 }
        return end
    }
}

/// The wording of a folded group: what its calls did, or what its last call is doing.
struct ToolGroupSummary: Equatable {
    let text: String
    let failed: Int

    /// `running` is whether the session runs: a call left unfinished by an ended session is not running.
    init(_ calls: [ACP.ToolCall], running: Bool) {
        failed = calls.count { $0.status == .failed }
        if running, let last = calls.last, last.status == .pending || last.status == .inProgress,
            let title = last.title.split(whereSeparator: \.isNewline).first?.replacing("`", with: ""),
            !title.isEmpty
        {
            text = "\(title)…"
            return
        }
        var counts: [Activity: Int] = [:]
        for call in calls { counts[Activity(call.kind), default: 0] += 1 }
        let phrases = Activity.allCases.compactMap { activity in counts[activity].map(activity.phrase) }
        let sentence = phrases.joined(separator: ", ")
        text = sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    func header(expanded: Bool) -> ToolCardHeader {
        ToolCardHeader(
            symbol: "wrench.and.screwdriver",
            kind: text,
            status: failed > 0 ? "· \(failed) failed" : "",
            tone: failed > 0 ? .failure : .neutral,
            expandable: true,
            expanded: expanded
        )
    }

    /// In the order the summary names them.
    private enum Activity: CaseIterable {
        case execute, read, edit, delete, move, search, fetch, think, other

        init(_ kind: ACP.ToolKind?) {
            self =
                switch kind {
                case .execute: .execute
                case .read: .read
                case .edit: .edit
                case .delete: .delete
                case .move: .move
                case .search: .search
                case .fetch: .fetch
                case .think: .think
                case .switchMode, .other, .unknown, nil: .other
                }
        }

        func phrase(_ count: Int) -> String {
            func counted(_ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
            return switch self {
            case .execute: "ran \(counted("command"))"
            case .read: "read \(counted("file"))"
            case .edit: "made \(counted("edit"))"
            case .delete: "deleted \(counted("file"))"
            case .move: "moved \(counted("file"))"
            case .search: "searched \(counted("time"))"
            case .fetch: "fetched \(counted("URL"))"
            case .think: "thought"
            case .other: "used \(counted("tool"))"
            }
        }
    }
}

extension TranscriptMessage {
    /// A group's row: only a header. It has no Markdown of its own; Copy returns `copyText`.
    init(group calls: [ACP.ToolCall], running: Bool, expanded: Bool, copyText: @escaping () -> String) {
        self.init(role: "Tool", markdown: "", text: NSAttributedString(string: ""))
        tool = ToolGroupSummary(calls, running: running).header(expanded: expanded)
        kind = .group
        self.copyText = copyText
    }
}
