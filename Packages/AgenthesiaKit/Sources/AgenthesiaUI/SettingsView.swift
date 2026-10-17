import AgenthesiaCore
import AppKit
public import SwiftUI

/// The app's settings. The editor choice is read by Open in Editor in every window.
public struct SettingsView: View {
    @AppStorage(EditorHandoff.defaultsKey) private var editorID = ""
    @State private var installed: [ExternalEditor] = []

    public init() {}

    public var body: some View {
        Form {
            Picker("Open files in", selection: $editorID) {
                Text("System default").tag("")
                ForEach(installed) { editor in
                    Text(editor.name).tag(editor.id)
                }
                if !editorID.isEmpty, !installed.contains(where: { $0.id == editorID }) {
                    Text("Not installed (\(ExternalEditor.named(editorID)?.name ?? editorID))").tag(editorID)
                }
            }
            Text(
                "Open in Editor in the file pane (⌥⌘O) uses this app. Visual Studio Code and Cursor open the file at the selected line; other editors open it at the start. If the app is not installed, the system's default app is used."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { installed = Self.installedEditors() }
    }

    /// The table's editors that are installed, in table order.
    static func installedEditors(
        appURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> [ExternalEditor] {
        ExternalEditor.all.filter { appURL($0.bundleIdentifier) != nil }
    }
}
