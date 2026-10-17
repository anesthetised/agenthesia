public import SwiftUI

extension FocusedValues {
    /// Opens the file shown in the focused window's file pane in the chosen editor.
    @Entry var openInEditor: (() -> Void)?
}

/// File menu commands. A menu item's shortcut works wherever focus is; a button's shortcut inside the
/// split view's file pane did not fire.
public struct FileCommands: Commands {
    @FocusedValue(\.openInEditor) private var openInEditor

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open in Editor") { openInEditor?() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(openInEditor == nil)
        }
    }
}
