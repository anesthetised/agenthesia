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
            case .live(let owner): liveRow(owner, project: row.project)
            case .saved(let record): savedRow(record, project: row.project)
            }
        }
    }

    private func liveRow(_ owner: LiveSession, project: ProjectRecord?) -> some View {
        let session = owner.controller?.session ?? owner.resuming
        return SessionRow(
            title: session?.title ?? "New Session",
            project: project?.name,
            outcome: session.flatMap { model.outcome(of: $0.id) },
            activity: owner.activity,
            started: session?.createdAt
        )
        .tag(SessionWindowModel.NavigationTarget.live(owner).id)
        .contextMenu {
            windowMenu(.live(owner))
            if let session { discardButton(session) }
        }
    }

    private func savedRow(_ record: SessionRecord, project: ProjectRecord?) -> some View {
        SessionRow(
            title: record.title ?? "New Session",
            project: project?.name,
            outcome: model.outcomes[record.id],
            activity: nil,
            started: record.createdAt
        )
        .tag(AnyHashable(record.id))
        .contextMenu {
            windowMenu(.saved(record))
            discardButton(record)
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
