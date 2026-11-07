import SwiftUI

/// The sidebar: Needs You in a list with the search field, the Working and Settled shelves pinned below (ADR-0039).
struct SessionSidebarColumn: View {
    let model: SessionWindowModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let sidebar = model.sidebar
        List(selection: Bindable(model).sidebarSelection) {
            SessionSidebarList(model: model)
        }
        .overlay {
            if sidebar.isFiltered && sidebar.rows.isEmpty {
                ContentUnavailableView.search(text: model.sidebarQuery)
            } else if sidebar.section(.needsYou) == nil {
                Text("Nothing needs you").foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarShelves(model: model) }
        .searchable(text: Bindable(model).sidebarQuery, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequests) { searchFocused = true }
    }
}
