import AgenthesiaCore
import SwiftUI

/// Working and Settled pinned to the bottom of the sidebar, Working above (ADR-0039): each a header that is always
/// visible while its section has rows and, when expanded, a list of its own that grows upward. Working takes at most
/// `workingShare` of the sidebar's height and Settled at most `settledShare`, less when the list above would keep less
/// than `topRoom`.
struct SidebarShelves: View {
    let model: SessionWindowModel
    @SceneStorage("sidebar.workingExpanded") private var workingExpanded = true
    @SceneStorage("sidebar.settledExpanded") private var settledExpanded = false
    /// The sidebar's height below the search field, measured by `heightProbe`.
    @State private var height: CGFloat = 0

    static let workingShare: CGFloat = 0.35
    static let settledShare: CGFloat = 0.45
    /// What the shelves leave on a short window: their two headers and about two rows of the list above.
    static let topRoom: CGFloat = 140
    /// A `SessionRow` in a sidebar list and the list's top and bottom padding. A `List` does not report its
    /// content height, so a shelf list sizes to its rows with this estimate.
    static let rowHeight: CGFloat = 38.5
    static let listPadding: CGFloat = 20

    /// A shelf list's height: its rows, but not more than `cap`.
    static func listHeight(rows: Int, cap: CGFloat) -> CGFloat { min(CGFloat(rows) * rowHeight + listPadding, cap) }

    /// The heights of the two lists in a sidebar `height` tall, given the rows of each open shelf (nil when closed).
    static func listHeights(height: CGFloat, working: Int?, settled: Int?) -> (working: CGFloat, settled: CGFloat) {
        let workingHeight = working.map { listHeight(rows: $0, cap: height * workingShare) } ?? 0
        let settledCap = max(0, min(height * settledShare, height - workingHeight - topRoom))
        return (workingHeight, settled.map { listHeight(rows: $0, cap: settledCap) } ?? 0)
    }

    static func accessibilityLabel(_ kind: SessionSidebar.Kind, count: Int, expanded: Bool) -> String {
        "\(kind.rawValue), \(count) \(count == 1 ? "session" : "sessions"), \(expanded ? "expanded" : "collapsed")"
    }

    var body: some View {
        let sidebar = model.sidebar
        let working = sidebar.section(.working)
        let settled = sidebar.section(.settled)
        let workingOpen = working.map { isOpen($0, stored: workingExpanded, filtered: sidebar.isFiltered) } ?? false
        let settledOpen = settled.map { isOpen($0, stored: settledExpanded, filtered: sidebar.isFiltered) } ?? false
        let heights = Self.listHeights(
            height: height,
            working: workingOpen ? working?.rows.count : nil,
            settled: settledOpen ? settled?.rows.count : nil
        )
        if working != nil || settled != nil {
            VStack(spacing: 0) {
                if let working {
                    SidebarShelf(
                        model: model,
                        section: working,
                        expanded: workingOpen,
                        listHeight: heights.working,
                        stored: $workingExpanded
                    )
                }
                if let settled {
                    SidebarShelf(
                        model: model,
                        section: settled,
                        expanded: settledOpen,
                        listHeight: heights.settled,
                        stored: $settledExpanded
                    )
                }
            }
            .background(.bar)
            .background(heightProbe)
        }
    }

    /// Open while one of its rows is selected, so keyboard navigation and restored windows never select a hidden
    /// row, and while a search shows its matches.
    private func isOpen(_ section: SessionSidebar.Section, stored: Bool, filtered: Bool) -> Bool {
        stored || filtered || section.rows.contains { $0.id == model.sidebarSelection }
    }

    private var heightProbe: some View {
        Color.clear
            .containerRelativeFrame(.vertical)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
    }
}

/// One shelf: a divider, the header button (chevron, section name, count) and, when expanded, the section's list.
private struct SidebarShelf: View {
    let model: SessionWindowModel
    let section: SessionSidebar.Section
    let expanded: Bool
    let listHeight: CGFloat
    /// The state the header toggles; `expanded` may be forced on beside it.
    @Binding var stored: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                stored = !expanded
            } label: {
                HStack {
                    Image(systemName: "chevron.right").rotationEffect(expanded ? .degrees(90) : .zero)
                    Text(section.kind.rawValue)
                    Spacer()
                    Text(section.rows.count, format: .number).monospacedDigit()
                }
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                SidebarShelves.accessibilityLabel(section.kind, count: section.rows.count, expanded: expanded)
            )
            if expanded {
                List(selection: Bindable(model).sidebarSelection) {
                    SessionSidebarRows(model: model, section: section)
                }
                .frame(height: listHeight)
            }
        }
    }
}
