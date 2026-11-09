import AgenthesiaCore
import SwiftUI

/// The session board (ADR-0046): one card per live session, Needs You then Working in sidebar order, in a grid that
/// wraps to the detail column's width. ⌘0 and the sidebar's Overview row show it.
struct SessionBoard: View {
    let model: SessionWindowModel
    @State private var width: CGFloat = 0

    static let cardMinWidth: CGFloat = 280
    static let maxColumns = 3
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 20

    /// The columns a grid `width` wide holds: as many cards of at least 280 pt as fit, one to three.
    static func columnCount(width: CGFloat) -> Int {
        max(1, min(maxColumns, Int((width + spacing) / (cardMinWidth + spacing))))
    }

    /// Every live session in sidebar order; the sidebar's search does not filter the board.
    @MainActor static func cards(_ model: SessionWindowModel) -> [SessionCard.Content] {
        SessionSidebar(
            projects: model.projects,
            history: [],
            owners: model.sessions.owners,
            activity: model.lastActivity
        )
        .rows.compactMap { row in
            guard case .live(let owner) = row.source else { return nil }
            return SessionCard.Content(owner: owner, row: row, model: model)
        }
    }

    var body: some View {
        let cards = Self.cards(model)
        if cards.isEmpty {
            ContentUnavailableView {
                Label("No agents running", systemImage: "square.grid.2x2")
            } actions: {
                Button("New Session") { model.showingSetup = true }.disabled(!model.canStart)
            }
        } else {
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top),
                count: Self.columnCount(width: width)
            )
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.spacing) {
                    ForEach(cards) { card in
                        SessionCard(content: card) { model.sidebarSelection = card.id }
                            .contextMenu { SessionRowMenu(model: model, row: card.row) }
                    }
                }
                .padding(Self.padding)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 - 2 * Self.padding }
        }
    }
}
