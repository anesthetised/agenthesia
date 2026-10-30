import AgenthesiaCore
import SwiftUI

/// Settled sessions pinned to the bottom of the sidebar (ADR-0039): a header that is always visible and, when
/// expanded, a list of its own that grows upward up to `maxShare` of the sidebar's height.
struct SettledFooter: View {
    let model: SessionWindowModel
    @SceneStorage("sidebar.settledExpanded") private var settledExpanded = false
    /// 45 % of the sidebar's height, measured by `capProbe`.
    @State private var cap: CGFloat = 0

    static let maxShare = 0.45
    /// A `SessionRow` in a sidebar list and the list's top and bottom padding. A `List` does not report its
    /// content height, so the footer list sizes to its rows with this estimate.
    static let rowHeight: CGFloat = 38.5
    static let listPadding: CGFloat = 20

    /// The footer list's height: its rows, but not more than `cap`.
    static func listHeight(rows: Int, cap: CGFloat) -> CGFloat { min(CGFloat(rows) * rowHeight + listPadding, cap) }

    static func accessibilityLabel(count: Int, expanded: Bool) -> String {
        "Settled, \(count) \(count == 1 ? "session" : "sessions"), \(expanded ? "expanded" : "collapsed")"
    }

    var body: some View {
        if let section = model.sidebar.sections.first(where: { $0.kind == .settled }) {
            // Open while one of its rows is selected, so keyboard navigation and restored windows never
            // select a hidden row.
            let expanded = settledExpanded || section.rows.contains { $0.id == model.sidebarSelection }
            VStack(spacing: 0) {
                Divider()
                Button {
                    settledExpanded = !expanded
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
                .accessibilityLabel(Self.accessibilityLabel(count: section.rows.count, expanded: expanded))
                if expanded {
                    List(selection: Bindable(model).sidebarSelection) {
                        SessionSidebarRows(model: model, section: section)
                    }
                    .frame(height: Self.listHeight(rows: section.rows.count, cap: cap))
                }
            }
            .background(.bar)
            .background(capProbe)
        }
    }

    private var capProbe: some View {
        Color.clear
            .containerRelativeFrame(.vertical) { length, _ in length * Self.maxShare }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { cap = $0 }
    }
}
