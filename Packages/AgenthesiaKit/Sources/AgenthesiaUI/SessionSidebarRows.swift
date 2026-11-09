import AgenthesiaCore
import Persistence
import SwiftUI

/// The rows of one sidebar section, tagged for the list's selection.
struct SessionSidebarRows: View {
    let model: SessionWindowModel
    let section: SessionSidebar.Section

    var body: some View {
        ForEach(section.rows) { row in
            switch row.source {
            case .live(let owner): liveRow(owner, row)
            case .saved(let record): savedRow(record, row)
            }
        }
    }

    private func liveRow(_ owner: LiveSession, _ row: SessionSidebar.Row) -> some View {
        SessionRow(
            title: row.title,
            project: row.project?.name,
            isScratch: model.isScratch(row.project),
            reason: model.reason(of: owner),
            activity: owner.activity,
            lastActivity: row.lastActivity,
            shelf: section.kind == .working,
            turnStartedAt: owner.controller?.turnStartedAt,
            onSettle: model.canSettle(owner) ? { Task { await model.settle(owner) } } : nil
        )
        .tag(SessionWindowModel.NavigationTarget.live(owner).id)
        .contextMenu { SessionRowMenu(model: model, row: row) }
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
        .contextMenu { SessionRowMenu(model: model, row: row) }
    }
}

extension SessionWindowModel {
    /// The reason a live session's row and card give: its status's, else its worktree's outcome.
    func reason(of owner: LiveSession) -> String? {
        owner.reason ?? (owner.controller?.session ?? owner.resuming).flatMap { outcome(of: $0.id) }?.label
    }
}

/// The context menu of a session row, and of its card on the board (ADR-0046).
struct SessionRowMenu: View {
    let model: SessionWindowModel
    let row: SessionSidebar.Row
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        newSessionButton(row.project)
        switch row.source {
        case .live(let owner):
            windowMenu(.live(owner))
            Button("Settle Session") { Task { await model.settle(owner) } }
                .disabled(!model.canSettle(owner))
            if let session = owner.controller?.session ?? owner.resuming, !model.isScratch(row.project) {
                discardButton(session)
            }
        case .saved(let record):
            windowMenu(.saved(record))
            archiveButton(record)
            Button("Delete Session…") { Task { await model.requestDelete(record) } }
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
