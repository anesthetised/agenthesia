import AgenthesiaCore
import Persistence
import SwiftUI

/// Needs You, the scrolling top of the sidebar (ADR-0039). Working and Settled are `SidebarShelves`.
struct SessionSidebarList: View {
    let model: SessionWindowModel

    var body: some View {
        if let section = model.sidebar.section(.needsYou) {
            Section(section.kind.rawValue) { SessionSidebarRows(model: model, section: section) }
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
