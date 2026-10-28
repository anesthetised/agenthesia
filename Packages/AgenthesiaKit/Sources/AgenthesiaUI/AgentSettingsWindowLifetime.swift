import AgenthesiaCore
import SwiftUI

/// Settings windows can keep their SwiftUI hierarchy after closing; observe the native window too.
struct AgentSettingsWindowLifetime: NSViewRepresentable {
    let catalog: AgentCatalog

    final class View: NSView {
        var catalog: AgentCatalog?
        private weak var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== observedWindow else { return }
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.willCloseNotification,
                    object: observedWindow
                )
            }
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowClosing),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }

        @objc private func windowClosing(_ notification: Notification) {
            guard let catalog, let flow = catalog.signIn else { return }
            Task { await catalog.closeSignIn(flow) }
        }
    }

    func makeNSView(context: Context) -> View { let view = View(); view.catalog = catalog; return view }
    func updateNSView(_ view: View, context: Context) { view.catalog = catalog }
}
