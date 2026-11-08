import AgenthesiaCore
import Persistence
import SwiftUI

/// The rows of one sidebar section, tagged for the list's selection.
struct SessionSidebarRows: View {
    let model: SessionWindowModel
    let section: SessionSidebar.Section
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(section.rows) { row in
            switch row.source {
            case .live(let owner): liveRow(owner, row)
            case .saved(let record): savedRow(record, row)
            }
        }
    }

    private func liveRow(_ owner: LiveSession, _ row: SessionSidebar.Row) -> some View {
        let session = owner.controller?.session ?? owner.resuming
        return SessionRow(
            title: row.title,
            project: row.project?.name,
            isScratch: model.isScratch(row.project),
            reason: owner.reason ?? session.flatMap { model.outcome(of: $0.id) }?.label,
            activity: owner.activity,
            lastActivity: row.lastActivity,
            shelf: section.kind == .working,
            turnStartedAt: owner.controller?.turnStartedAt,
            onSettle: model.canSettle(owner) ? { Task { await model.settle(owner) } } : nil
        )
        .tag(SessionWindowModel.NavigationTarget.live(owner).id)
        .contextMenu {
            newSessionButton(row.project)
            windowMenu(.live(owner))
            Button("Settle Session") { Task { await model.settle(owner) } }
                .disabled(!model.canSettle(owner))
            if let session, !model.isScratch(row.project) { discardButton(session) }
        }
    }

    private func savedRow(_ record: SessionRecord, _ row: SessionSidebar.Row) -> some View {
        SessionRow(
            title: row.title,
            project: row.project?.name,
            isScratch: model.isScratch(row.project),
            reason: SidebarReason.saved(archived: record.archivedAt != nil, outcome: model.outcomes[record.id]?.label),
            activity: nil,
            lastActivity: row.lastActivity
        )
        .tag(AnyHashable(record.id))
        .contextMenu {
            newSessionButton(row.project)
            windowMenu(.saved(record))
            archiveButton(record)
            // A session without a project has no worktree (ADR-0048).
            if !model.isScratch(row.project) { discardButton(record) }
        }
    }

    /// Opens the draft with the row's project; a starting session has no project yet.
    @ViewBuilder private func newSessionButton(_ project: ProjectRecord?) -> some View {
        if let project {
            Button("New Session in Project") { model.newSession(in: project) }
                .disabled(!model.canStart)
        }
    }

    private func archiveButton(_ record: SessionRecord) -> some View {
        Button(SessionWindowModel.archiveTitle(archived: record.archivedAt != nil)) {
            Task { await model.setArchived(record.archivedAt == nil, record) }
        }
    }

    private func discardButton(_ session: SessionRecord) -> some View {
        Button("Discard Worktree…") { Task { await model.requestDiscard(session) } }
            .disabled(!model.canDiscard(session))
    }

    /// Shows the session in its own window, or raises the window that already has it.
    @ViewBuilder private func windowMenu(_ target: SessionWindowModel.NavigationTarget) -> some View {
        if let windowTarget = target.windowTarget {
            Button("Open in New Window") { openWindow(value: windowTarget) }
        }
    }
}
