import AgenthesiaCore
import Persistence
import SwiftUI

/// Projects → sessions with live statuses (ADR-0026).
struct SessionSidebarList: View {
    let model: SessionWindowModel
    @Environment(\.openWindow) private var openWindow

    private var sidebar: SessionSidebar { model.sidebar }

    var body: some View {
        if !sidebar.starting.isEmpty {
            Section("Starting") {
                ForEach(sidebar.starting) { owner in liveRow(owner) }
            }
        }
        ForEach(sidebar.groups) { group in
            Section(group.project.name) {
                ForEach(group.rows) { row in
                    switch row {
                    case .live(let owner, _): liveRow(owner)
                    case .saved(let record): savedRow(record)
                    }
                }
            }
        }
    }

    private func liveRow(_ owner: LiveSession) -> some View {
        let title = owner.controller?.session.title ?? owner.resuming?.title ?? "Starting session"
        return HStack {
            Text(title).lineLimit(1)
            Spacer()
            StatusIcon(activity: owner.activity)
        }
        .contentShape(.rect)
        .tag(SessionWindowModel.NavigationTarget.live(owner).id)
        .accessibilityElement(children: .combine)
        .contextMenu {
            windowMenu(.live(owner))
            if let session = owner.controller?.session ?? owner.resuming { discardButton(session) }
        }
    }

    private func savedRow(_ record: SessionRecord) -> some View {
        VStack(alignment: .leading) {
            Text(record.title ?? "Session").lineLimit(1)
            Group {
                if let outcome = model.outcomes[record.id] {
                    Text("\(record.createdAt, style: .date) · \(outcome.label)")
                } else {
                    Text(record.createdAt, style: .date)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(.rect)
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

private struct StatusIcon: View {
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
