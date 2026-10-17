public import Foundation
public import Persistence

/// Projects with their sessions for the sidebar (ADR-0026).
@MainActor public struct SessionSidebar {
    public enum Row: Identifiable {
        case live(LiveSession, id: UUID)
        case saved(SessionRecord)

        public var id: UUID {
            switch self {
            case .live(_, let id): id
            case .saved(let record): record.id
            }
        }
    }

    public struct Group: Identifiable {
        public let project: ProjectRecord
        public let rows: [Row]
        public var id: UUID { project.id }
    }

    /// Owners that are starting a new session and have no project yet.
    public let starting: [LiveSession]
    /// Ordered by each project's most recent session.
    public let groups: [Group]

    /// Live sessions come first in start order, then saved sessions newest first.
    public init(projects: [ProjectRecord], history: [SessionRecord], owners: [LiveSession]) {
        let known = Set(projects.map(\.id))
        let records = owners.map { ($0, $0.controller?.session ?? $0.resuming) }
        starting = records.filter { $0.1.map { !known.contains($0.projectID) } ?? true }.map(\.0)
        let liveIDs = Set(records.compactMap { $0.1?.id })
        groups =
            projects.compactMap { project -> (Group, Date)? in
                let live = records.compactMap { owner, session in
                    session.flatMap { $0.projectID == project.id ? (owner, $0) : nil }
                }
                let saved = history.filter { $0.projectID == project.id && !liveIDs.contains($0.id) }
                    .sorted { $0.createdAt > $1.createdAt }
                guard !live.isEmpty || !saved.isEmpty else { return nil }
                let newest = (live.map(\.1) + saved).map(\.createdAt).max() ?? .distantPast
                let rows = live.map { Row.live($0.0, id: $0.1.id) } + saved.map(Row.saved)
                return (Group(project: project, rows: rows), newest)
            }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }
}
