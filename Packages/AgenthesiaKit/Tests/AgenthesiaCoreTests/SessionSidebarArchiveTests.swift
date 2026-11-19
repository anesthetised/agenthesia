import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionSidebarArchiveTests {
    private let project = ProjectRecord(name: "Project", rootPath: "/p")

    private func saved(
        _ title: String,
        age: TimeInterval,
        archived: Bool = false,
        settled: Bool = true
    ) -> SessionRecord {
        SessionRecord(
            projectID: project.id,
            agentInstallID: UUID(),
            title: title,
            workingDirectory: project.rootPath,
            archivedAt: archived ? Date(timeIntervalSinceNow: -1) : nil,
            settledAt: settled ? Date(timeIntervalSinceNow: -1) : nil,
            createdAt: Date(timeIntervalSinceNow: -age)
        )
    }

    @Test func archivedSessionsLeaveSettledAndItsCount() {
        let (kept, hidden) = (saved("Kept", age: 10), saved("Hidden", age: 20, archived: true))
        let sidebar = SessionSidebar(projects: [project], history: [hidden, kept], owners: [])
        #expect(sidebar.sections.map(\.kind) == [.settled])
        #expect(sidebar.sections.first?.rows.count == 1)
        #expect(sidebar.rows.map(\.id) == [AnyHashable(kept.id)])
    }

    /// Saved sessions that are not settled are in the list, by start; settled ones on the shelf (ADR-0050).
    @Test func savedSessionsThatAreNotSettledAreInTheList() {
        let (older, newer) = (saved("Older", age: 30, settled: false), saved("Newer", age: 10, settled: false))
        let (done, hidden) = (saved("Done", age: 20), saved("Hidden", age: 5, archived: true, settled: false))
        let sidebar = SessionSidebar(projects: [project], history: [newer, done, hidden, older], owners: [])
        #expect(sidebar.sections.map(\.kind) == [.active, .settled])
        #expect(sidebar.section(.active)?.rows.map(\.id) == [AnyHashable(older.id), AnyHashable(newer.id)])
        #expect(sidebar.section(.settled)?.rows.map(\.id) == [AnyHashable(done.id)])
        #expect(sidebar.needsYou.isEmpty)
        #expect(sidebar.numberedRows.map(\.id) == [AnyHashable(older.id), AnyHashable(newer.id)])
        // A search lists an archived session among the settled ones, whatever its `settledAt`.
        let found = SessionSidebar(projects: [project], history: [newer, hidden], owners: [], query: "hidden")
        #expect(found.sections.map(\.kind) == [.settled])
    }

    @Test func settledIsOmittedWhenEverySavedSessionIsArchived() {
        let sidebar = SessionSidebar(
            projects: [project],
            history: [saved("One", age: 1, archived: true), saved("Two", age: 2, archived: true)],
            owners: []
        )
        #expect(sidebar.sections.isEmpty && sidebar.rows.isEmpty && !sidebar.isFiltered)
    }

    @Test func aSearchListsArchivedSessionsInSettledOrder() {
        let (newer, older) = (saved("Fix login", age: 10), saved("Fix logout", age: 30, archived: true))
        let history = [older, newer, saved("Docs", age: 20, archived: true)]
        let found = SessionSidebar(projects: [project], history: history, owners: [], query: "fix")
        #expect(found.sections.map(\.kind) == [.settled])
        #expect(found.rows.map(\.id) == [AnyHashable(newer.id), AnyHashable(older.id)])
        // Settled's count in a search is its matches, archived ones included.
        #expect(found.sections.first?.rows.count == 2)
        let onlyArchived = SessionSidebar(projects: [project], history: history, owners: [], query: "docs")
        #expect(onlyArchived.rows.count == 1)
        guard case .saved(let record) = onlyArchived.rows.first?.source else {
            Issue.record("expected a saved row")
            return
        }
        #expect(record.archivedAt != nil)
        #expect(SidebarReason.saved(archived: record.archivedAt != nil, outcome: "Merged") == "Archived")
    }
}
