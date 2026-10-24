import AppKit
import SwiftUI

/// What the Dock tile shows: a star for each live session, and open eyes while one needs the user (ADR-0031).
struct DockIconState: Equatable {
    let live: Int
    let awake: Bool

    var stars: Int { min(live, AppIcon.maxStars) }
}

/// Draws the Dock tile while sessions are live. With none, the icon from the asset catalog returns, with the
/// system's own treatment of it.
@MainActor final class DockTileRenderer {
    private var hosting: NSHostingView<AppIcon>?

    func show(_ state: DockIconState) {
        let tile = NSApp.dockTile
        guard state.live > 0 else {
            tile.contentView = nil
            hosting = nil
            tile.display()
            return
        }
        let icon = AppIcon(stars: state.stars, awake: state.awake)
        if let hosting {
            hosting.rootView = icon
        } else {
            let view = NSHostingView(rootView: icon)
            view.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = view
            hosting = view
        }
        tile.display()
    }
}
