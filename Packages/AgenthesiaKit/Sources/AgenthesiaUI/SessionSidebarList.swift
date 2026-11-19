import AgenthesiaCore
import Persistence
import SwiftUI

/// The Overview row (ADR-0046) and the open sessions that are not working, the scrolling top of the sidebar
/// (ADR-0039). Working and Settled are `SidebarShelves`.
struct SessionSidebarList: View {
    let model: SessionWindowModel
    /// The list's rows, from the column's `model.sidebar`: read there, a move between the list and a shelf takes the
    /// column's animation.
    let section: SessionSidebar.Section?

    var body: some View {
        Label("Overview", systemImage: "square.grid.2x2").tag(SessionWindowModel.overviewID)
        // No section: the rows follow Overview at their own spacing.
        if let section { SessionSidebarRows(model: model, section: section) }
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
