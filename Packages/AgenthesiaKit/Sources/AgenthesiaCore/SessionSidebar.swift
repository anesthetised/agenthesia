public import Foundation
public import Persistence

/// Sessions grouped by what they ask of the user (ADR-0039, superseding the project groups of ADR-0026).
@MainActor public struct SessionSidebar {
    public enum Kind: String, CaseIterable, Sendable {
        case needsYou = "Needs You"
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

        /// The session's identity once it has one; a starting owner is identified by itself.
        public let id: AnyHashable

        @MainActor init(source: Source, project: ProjectRecord?) {
            self.source = source
            self.project = project
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
    }

    /// Needs You, Working and Settled in that order; empty sections are omitted.
    public let sections: [Section]

    /// All rows in the order the sidebar shows them.
    public var rows: [Row] { sections.flatMap(\.rows) }

    /// - Needs You: live sessions that wait for a permission or input, failed, or finished unseen, in start order.
    /// - Working: the other live sessions, including starting ones, in start order.
    /// - Settled: saved sessions that are not live, newest first.
    public init(projects: [ProjectRecord], history: [SessionRecord], owners: [LiveSession]) {
        let projects = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let live = owners.map { owner in
            (
                owner,
                Row(
                    source: .live(owner),
                    project: (owner.controller?.session ?? owner.resuming).flatMap { projects[$0.projectID] }
                )
            )
        }
        let liveIDs = Set(owners.compactMap(\.sessionID))
        let kinds: [(Kind, [Row])] = [
            (.needsYou, live.filter { [.needsInput, .failed, .done].contains($0.0.activity) }.map(\.1)),
            (.working, live.filter { ![.needsInput, .failed, .done].contains($0.0.activity) }.map(\.1)),
            (
                .settled,
                history.filter { !liveIDs.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
                    .map { Row(source: .saved($0), project: projects[$0.projectID]) }
            ),
        ]
        sections = kinds.filter { !$0.1.isEmpty }.map { Section(kind: $0.0, rows: $0.1) }
    }
}
