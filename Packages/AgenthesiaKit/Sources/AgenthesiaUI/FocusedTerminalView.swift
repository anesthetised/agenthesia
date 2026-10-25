import AppKit
import SwiftTerm

/// Takes keyboard focus when shown, so typing goes to the command at once.
final class FocusedTerminalView: TerminalView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
