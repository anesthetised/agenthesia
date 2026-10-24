import AppKit
import SwiftUI

/// What the Dock tile shows: a star for each live session, and open eyes while one needs the user (ADR-0031).
struct DockIconState: Equatable {
    let live: Int
    let awake: Bool

    var stars: Int { min(live, AppIcon.maxStars) }
}

extension AppIcon.Style {
    /// The night sky in Dark Mode. The app can read the appearance but not the icon style chosen in System
    /// Settings, so a Dark icon style on a light appearance still gets the sky.
    init(_ appearance: NSAppearance) {
        self = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .night : .sky
    }
}

/// Draws the Dock tile while sessions are live. With none, the icon from `AppIcon.icon` returns, with the
/// system's own treatment of it.
@MainActor final class DockTileRenderer {
    private var state: DockIconState?
    private var hosting: NSHostingView<AppIcon>?
    private var appearanceObservation: NSKeyValueObservation?

    func show(_ state: DockIconState) {
        self.state = state
        if appearanceObservation == nil {
            appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.draw() }
            }
        }
        draw()
    }

    private func draw() {
        let tile = NSApp.dockTile
        guard let state, state.live > 0 else {
            tile.contentView = nil
            hosting = nil
            tile.display()
            return
        }
        let icon = AppIcon(stars: state.stars, awake: state.awake, style: Style(NSApp.effectiveAppearance))
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

    private typealias Style = AppIcon.Style
}
