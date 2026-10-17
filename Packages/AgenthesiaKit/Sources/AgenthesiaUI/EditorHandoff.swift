import AgenthesiaCore
import AppKit

/// Hands the file in the file pane to the editor chosen in Settings (ADR-0025).
enum EditorHandoff {
    /// `UserDefaults` key of the chosen editor's bundle identifier; empty means the system default app.
    static let defaultsKey = "editorBundleIdentifier"

    enum Action: Equatable {
        /// An editor URL that opens the file at a line.
        case url(URL)
        /// The file in a specific app, without a line.
        case file(URL, app: URL)
        /// The file in the app macOS chooses.
        case systemDefault(URL)
    }

    /// `appURL` is where the chosen editor is installed, if it is.
    static func action(
        path: String,
        line: Int?,
        root: URL,
        editor: ExternalEditor?,
        appURL: URL?
    ) -> Action {
        let file = root.appending(path: path)
        guard let editor, let appURL else { return .systemDefault(file) }
        if let line, let url = editor.url(opening: path, line: line, in: root) { return .url(url) }
        return .file(file, app: appURL)
    }

    @discardableResult
    static func open(
        path: String,
        line: Int?,
        root: URL,
        editorID: String,
        workspace: NSWorkspace = .shared
    ) -> Action {
        let action = action(
            path: path,
            line: line,
            root: root,
            editor: ExternalEditor.named(editorID),
            appURL: workspace.urlForApplication(withBundleIdentifier: editorID)
        )
        switch action {
        case .url(let url): workspace.open(url)
        case .file(let file, let app):
            workspace.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .systemDefault(let file): workspace.open(file)
        }
        return action
    }
}
