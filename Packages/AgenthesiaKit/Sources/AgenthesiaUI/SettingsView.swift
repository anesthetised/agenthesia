public import AgenthesiaCore
import AppKit
public import SwiftUI

/// The app's settings: General, and Agents (ADR-0036).
public struct SettingsView: View {
    private let catalog: AgentCatalog

    public init(catalog: AgentCatalog) { self.catalog = catalog }

    public var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Agents", systemImage: "cpu") {
                AgentsSettings(catalog: catalog).frame(width: 600, height: 560)
            }
        }
        .background { AgentSettingsWindowLifetime(catalog: catalog) }
    }

    /// The table's editors that are installed, in table order.
    static func installedEditors(
        appURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> [ExternalEditor] {
        ExternalEditor.all.filter { appURL($0.bundleIdentifier) != nil }
    }
}

/// The editor choice is read by Open in Editor in every window.
struct GeneralSettings: View {
    @AppStorage(EditorHandoff.defaultsKey) private var editorID = ""
    @State private var installed: [ExternalEditor] = []

    var body: some View {
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
                "Open in Editor (⌥⌘O) uses this app. Visual Studio Code, Cursor and Zed open the file at the selected line; Xcode opens it at the start. If the app is not installed, the system's default app is used."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { installed = SettingsView.installedEditors() }
    }
}
