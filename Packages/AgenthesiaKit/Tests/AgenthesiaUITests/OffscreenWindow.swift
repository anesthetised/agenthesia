import AppKit
import SwiftUI

/// The window hosted tests put their views in: `let window = OffscreenWindow(size: …)`, then
/// `window.contentView = NSHostingView(rootView: …)`. It has the chrome of the window `WindowGroup` makes for the app,
/// so layout near the top edge measures what the app has, and it sits off every screen, so a test run shows nothing.
///
/// Without `.fullSizeContentView` the toolbar draws as a band above the content and `RootView`'s detail column and
/// inspector start below it; the app's window lets the content run under the toolbar and insets it by the safe area.
@MainActor final class OffscreenWindow: NSWindow {
    /// `size` is the whole window, as `defaultSize` is for the app's window: the content runs under the title bar.
    ///
    /// A view's display link, which `SessionFrameDriver` publishes streamed transcript frames with, only ticks in a window
    /// on a screen. A test that streams into the hosted view passes `drivesDisplayLink`: the window then sits on the
    /// screen, fully transparent and deaf to the mouse, so it still shows nothing.
    init(size: CGSize, drivesDisplayLink: Bool = false) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        // `init` pulls the window onto a screen, so the position is set afterwards.
        setFrameOrigin(drivesDisplayLink ? .zero : Self.origin)
        if drivesDisplayLink {
            alphaValue = 0
            ignoresMouseEvents = true
        }
        toolbarStyle = .unified
    }

    /// Far outside any arrangement of displays.
    private static let origin = CGPoint(x: -30_000, y: -30_000)

    /// Titled windows are pulled back onto a screen when they are shown; this one stays where it was put.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
