import AgenthesiaCore
import SwiftUI

/// The sidebar: the open sessions in a list with the search field, the Working and Settled shelves pinned below
/// (ADR-0039).
struct SessionSidebarColumn: View {
    let model: SessionWindowModel
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the list shows in place of rows: the search's No Results, or `No open sessions` without list rows.
    enum Placeholder { case noResults, noOpenSessions }

    static func placeholder(_ sidebar: SessionSidebar) -> Placeholder? {
        if sidebar.isFiltered && sidebar.rows.isEmpty { return .noResults }
        return sidebar.section(.active) == nil ? .noOpenSessions : nil
    }

    /// The rows of the list and of the Working shelf: a row that moves between them, starts or ends animates.
    /// One slot per section, so that a lone row's move from one to the other changes the value.
    static func liveRows(_ sidebar: SessionSidebar) -> [[AnyHashable]] {
        [.active, .working].map { sidebar.section($0)?.rows.map(\.id) ?? [] }
    }

    var body: some View {
        let sidebar = model.sidebar
        List(selection: Bindable(model).sidebarSelection) {
            SessionSidebarList(model: model, section: sidebar.section(.active))
        }
        .overlay {
            switch Self.placeholder(sidebar) {
            case .noResults: ContentUnavailableView.search(text: model.sidebarQuery)
            case .noOpenSessions: Text("No open sessions").foregroundStyle(.secondary)
            case nil: EmptyView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarShelves(model: model, sidebar: sidebar) }
        // A search filters at once.
        .animation(
            sidebar.isFiltered ? nil : SidebarShelves.animation(reduceMotion: reduceMotion),
            value: Self.liveRows(sidebar)
        )
        .searchable(text: Bindable(model).sidebarQuery, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequests) { searchFocused = true }
    }
}
