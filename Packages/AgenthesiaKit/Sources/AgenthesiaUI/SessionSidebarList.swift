import AgenthesiaCore
import Persistence
import SwiftUI

/// Sessions by status: Needs You, Working, Settled (ADR-0039).
struct SessionSidebarList: View {
    let model: SessionWindowModel
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("sidebar.settledExpanded") private var settledExpanded = false

    private var sidebar: SessionSidebar { model.sidebar }

    var body: some View {
        ForEach(sidebar.sections) { section in
            if section.kind == .settled {
                Section(isExpanded: settledBinding(section)) {
                    rows(section)
                } header: {
                    HStack {
                        Text(section.kind.rawValue)
                        Spacer()
                        Text(section.rows.count, format: .number).monospacedDigit()
                    }
                }
            } else {
                Section(section.kind.rawValue) { rows(section) }
            }
        }
    }

    /// Collapsed by default and remembered per window. It stays open while one of its rows is selected,
    /// so keyboard navigation and restored windows never select a hidden row.
    private func settledBinding(_ section: SessionSidebar.Section) -> Binding<Bool> {
        let selected = section.rows.contains { $0.id == model.sidebarSelection }
        return Binding(get: { settledExpanded || selected }, set: { settledExpanded = $0 })
    }

    private func rows(_ section: SessionSidebar.Section) -> some View {
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

extension WorktreeOutcome {
    /// The short form shown under a saved session.
    var label: String {
        switch self {
        case .merged: "Merged"
        case .discarded: "Discarded"
        }
    }
}

struct StatusIcon: View {
    let activity: LiveSession.Activity

    var body: some View {
        switch activity {
        case .working: ProgressView().controlSize(.small).accessibilityLabel(activity.rawValue)
        case .idle: EmptyView()
        case .needsInput: icon("exclamationmark.bubble.fill", .orange)
        case .failed: icon("exclamationmark.triangle.fill", .red)
        case .done: icon("circle.fill", .blue)
        }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).foregroundStyle(color).accessibilityLabel(activity.rawValue)
    }
}
