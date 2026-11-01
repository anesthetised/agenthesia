import SwiftUI

/// The sidebar: Needs You and Working in a list with the search field, Settled pinned below (ADR-0039).
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
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SettledFooter(model: model) }
        .searchable(text: Bindable(model).sidebarQuery, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequests) { searchFocused = true }
    }
}
