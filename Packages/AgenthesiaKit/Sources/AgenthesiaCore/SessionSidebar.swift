public import Foundation
public import Persistence

/// Sessions grouped by what they ask of the user (ADR-0039, superseding the project groups of ADR-0026).
@MainActor public struct SessionSidebar {
    public enum Kind: String, CaseIterable, Sendable {
        /// The scrolling list, which has no header: the open sessions that are not in a turn.
        case active = "Active"
        case working = "Working"
        case settled = "Settled"
    }

    public struct Row: Identifiable {
        public enum Source {
            case live(LiveSession)
            case saved(SessionRecord)
        }

        public let source: Source
        /// Nil while a starting session has no project yet, or when the project is unknown.
        public let project: ProjectRecord?

        /// When the session last did anything: the log's last event, or its start without one. Nil while a starting
        /// session has no record yet.
        public let lastActivity: Date?

        /// The session's identity once it has one; a starting owner is identified by itself.
        public let id: AnyHashable

        /// What the sidebar shows as the session's title.
        @MainActor public var title: String {
            switch source {
            case .live(let owner): (owner.controller?.session ?? owner.resuming)?.title ?? "New Session"
            case .saved(let record): record.title ?? "New Session"
            }
        }

        @MainActor func matches(_ query: String) -> Bool {
            title.localizedStandardContains(query) || project?.name.localizedStandardContains(query) == true
        }

        @MainActor init(source: Source, project: ProjectRecord?, savedActivity: [UUID: Date] = [:]) {
            self.source = source
            self.project = project
            lastActivity =
                switch source {
                case .live(let owner):
                    owner.controller?.lastActivity ?? owner.sessionID.flatMap { savedActivity[$0] }
                        ?? (owner.controller?.session ?? owner.resuming)?.createdAt
                case .saved(let record): savedActivity[record.id] ?? record.createdAt
                }
            id =
                switch source {
                case .live(let owner): owner.sessionID.map(AnyHashable.init) ?? AnyHashable(owner.id)
                case .saved(let record): AnyHashable(record.id)
                }
        }
    }

    public struct Section: Identifiable {
        public let kind: Kind
        public let rows: [Row]
        public var id: Kind { kind }

        public init(kind: Kind, rows: [Row]) {
            self.kind = kind
            self.rows = rows
        }
    }

    /// The list, Working and Settled in that order; empty sections are omitted.
    public let sections: [Section]

    /// Whether a query was applied, so empty `sections` mean "no matches" rather than "no sessions".
    public let isFiltered: Bool

    /// All rows in the order the sidebar shows them.
    public var rows: [Row] { sections.flatMap(\.rows) }

    /// The section of that kind, or nil when it has no rows.
    public func section(_ kind: Kind) -> Section? { sections.first { $0.kind == kind } }

    /// The rows that need the user, at the top of the list: needs input, failed or done. The menu bar lists them
    /// under Needs You.
    public var needsYou: [Row] {
        (section(.active)?.rows ?? []).filter {
            if case .live(let owner) = $0.source { Self.needsYou(owner.activity) } else { false }
        }
    }

    static func needsYou(_ activity: LiveSession.Activity) -> Bool { [.needsInput, .failed, .done].contains(activity) }

    /// Whether a live session is on the Working shelf: in a turn, or between the turns of a queue that is about to
    /// start the next one, so that its row does not bounce between the shelf and the list.
    static func isWorking(_ activity: LiveSession.Activity, queueDue: Bool) -> Bool {
        activity == .working || (queueDue && [.idle, .done].contains(activity))
    }

    /// An idle session's queue starts its next turn on its own: it is not paused, held by an edit or behind a merge.
    static func queueDue(_ controller: SessionController?) -> Bool {
        guard let controller else { return false }
        return controller.status == .idle && !controller.queuePaused && controller.queueEdits == 0
            && !controller.isMerging && !controller.queuedPrompts.isEmpty
    }

    /// The trailing text of a row on the Working shelf: `Working 1m 12s` from the turn's start while one runs. Nil
    /// without a turn: a starting session's spinner and reason say it, and a row between queued turns shows no time.
    public static func shelfTime(turnStartedAt: Date?, now: Date = .now) -> String? {
        turnStartedAt.map { "Working \(WorkingDuration.format(now.timeIntervalSince($0)))" }
    }

    /// How many rows ⌘1…⌘9 reach.
    public static let numberedCount = 9

    /// The rows ⌘1…⌘9 select (ADR-0046): the first nine of the list and Working in the order on screen, after the
    /// query. Settled is not numbered.
    public var numberedRows: [Row] {
        Array(sections.filter { $0.kind != .settled }.flatMap(\.rows).prefix(Self.numberedCount))
    }

    /// - The list: live sessions that are not working (`isWorking`), those that wait for a permission or input,
    ///   failed, or finished unseen first, then the idle ones; each group in start order.
    /// - Working: live sessions that are starting, running or stopping, or about to start a queued turn, in start
    ///   order.
    /// - Settled: saved sessions that are not live or archived, by last activity, newest first. `activity` holds the
    ///   time of each saved session's last event; a session without an entry sorts by its start.
    /// A non-blank `query` keeps the rows whose title or project name contains it, ignoring case and diacritics.
    /// Only a query lists archived sessions (ADR-0044).
    public init(
        projects: [ProjectRecord],
        history: [SessionRecord],
        owners: [LiveSession],
        activity: [UUID: Date] = [:],
        query: String = ""
    ) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = !query.isEmpty
        isFiltered = filtered
        let projects = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let live = owners.map { owner in
            (
                owner,
                Row(
                    source: .live(owner),
                    project: (owner.controller?.session ?? owner.resuming).flatMap { projects[$0.projectID] },
                    savedActivity: activity
                )
            )
        }
        let liveIDs = Set(owners.compactMap(\.sessionID))
        func onShelf(_ owner: LiveSession) -> Bool {
            Self.isWorking(owner.activity, queueDue: Self.queueDue(owner.controller))
        }
        let open = live.filter { !onShelf($0.0) }
        let kinds: [(Kind, [Row])] = [
            (
                .active,
                (open.filter { Self.needsYou($0.0.activity) } + open.filter { !Self.needsYou($0.0.activity) }).map(\.1)
            ),
            (.working, live.filter { onShelf($0.0) }.map(\.1)),
            (
                .settled,
                history.filter { !liveIDs.contains($0.id) && (filtered || $0.archivedAt == nil) }
                    .map { Row(source: .saved($0), project: projects[$0.projectID], savedActivity: activity) }
                    .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            ),
        ]
        sections = kinds.map { ($0.0, $0.1.filter { !filtered || $0.matches(query) }) }
            .filter { !$0.1.isEmpty }.map { Section(kind: $0.0, rows: $0.1) }
    }
}
