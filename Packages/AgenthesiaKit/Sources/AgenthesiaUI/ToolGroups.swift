import ACP
import AgenthesiaCore
import Foundation

/// A display row of the transcript, identified by item index; items only append, so an index stays valid.
enum TranscriptRow: Hashable {
    case item(Int)
    /// A summary of two or more consecutive tool calls, the first of them at this item.
    case group(first: Int)
    /// One or more consecutive thoughts, the first of them at this item (ADR-0039's amendment).
    case thoughts(first: Int)
    /// A finished turn's work, `Worked for 1m 3s`, from this item, the first after its prompt, on (#341).
    case turn(first: Int)

    /// One tool call stays a plain card; any other item, such as a permission request or input form, ends a group.
    /// An expanded group's calls follow its summary as plain cards. Thoughts always fold, into one row that holds
    /// them all. A turn's row comes before its items; collapsed, only the items it keeps follow it.
    static func fold(
        count: Int,
        isToolCall: (Int) -> Bool,
        isThought: (Int) -> Bool,
        isExpanded: (Int) -> Bool,
        turns: [TurnFold] = []
    ) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(count)
        var turns = turns[...]
        var index = 0
        while index < count {
            if let turn = turns.first, turn.items.lowerBound == index {
                turns.removeFirst()
                rows.append(.turn(first: index))
                if !turn.expanded {
                    rows += turn.kept.map(TranscriptRow.item)
                    index = turn.items.upperBound
                    continue
                }
            }
            if isThought(index) {
                rows.append(.thoughts(first: index))
                index = groupEnd(from: index, count: count, while: isThought)
                continue
            }
            let end = groupEnd(from: index, count: count, while: isToolCall)
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

    /// The row that shows item `index`: its own, or the summary of the folded group or thoughts it is in.
    static func row(showing index: Int, in rows: [TranscriptRow]) -> Int? {
        rows.lastIndex { row in
            switch row {
            case .item(let item): item <= index
            case .group(let first), .thoughts(let first), .turn(let first): first <= index
            }
        }
    }

    /// What an item is to the turn it is in.
    enum TurnPart: Equatable {
        /// A prompt of this turn; prompts sent together are consecutive.
        case prompt(UUID)
        /// An agent message: the turn's last one is its answer and stays shown.
        case answer
        /// An input form, which stays shown.
        case question
        /// A tool call, a thought or a permission record.
        case work
        /// Anything that ends a turn's items, such as a notice, a failure or an interruption.
        case other
    }

    /// The turns that `finished` tells ended on their own, with work to fold: everything after the prompt up to the
    /// next prompt or other item, except the answer and the questions.
    static func turnFolds(
        count: Int,
        part: (Int) -> TurnPart,
        finished: (UUID) -> Bool,
        isExpanded: (UUID) -> Bool
    ) -> [TurnFold] {
        var folds: [TurnFold] = []
        var index = 0
        while index < count {
            guard case .prompt(let turn) = part(index) else {
                index += 1
                continue
            }
            var first = index + 1
            while first < count, part(first) == .prompt(turn) { first += 1 }
            var end = first
            var answer: Int?
            var kept: [Int] = []
            scan: while end < count {
                switch part(end) {
                case .answer: answer = end
                case .question: kept.append(end)
                case .work: break
                case .prompt, .other: break scan
                }
                end += 1
            }
            index = end
            if let answer { kept.insert(answer, at: kept.firstIndex { $0 > answer } ?? kept.endIndex) }
            guard end - first > kept.count, finished(turn) else { continue }
            folds.append(TurnFold(turn: turn, items: first..<end, kept: kept, expanded: isExpanded(turn)))
        }
        return folds
    }

    /// The end of the run of items at `first` that `matches` accepts.
    static func groupEnd(from first: Int, count: Int, while matches: (Int) -> Bool) -> Int {
        var end = first
        while end < count, matches(end) { end += 1 }
        return end
    }
}

/// A finished turn's work under one row (#341).
struct TurnFold: Equatable {
    let turn: UUID
    /// From the first item after the prompt to the end of the turn's items.
    let items: Range<Int>
    /// The items shown below a collapsed row: the answer and the questions, in order.
    let kept: [Int]
    let expanded: Bool

    /// `Worked for 1m 3s`, a chevron and a hairline; expanding it adds the rows it hides below it.
    static func message(duration: TimeInterval, expanded: Bool) -> TranscriptMessage {
        var message = TranscriptMessage(role: "Turn", markdown: "", text: NSAttributedString(string: ""))
        message.kind = .turn
        message.tool = ToolCardHeader(
            symbol: expanded ? "chevron.down" : "chevron.right",
            kind: "Worked for \(WorkingDuration.format(duration))",
            status: "",
            tone: .neutral,
            expandable: true,
            expanded: expanded
        )
        return message
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
