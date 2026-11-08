public import AgenthesiaCore
import AppKit
public import SwiftUI

/// The app's settings: General, and Agents (ADR-0036).
public struct SettingsView: View {
    private let catalog: AgentCatalog
    @AppStorage(SettingsTab.defaultsKey) private var selection = SettingsTab.general

    public init(catalog: AgentCatalog) { self.catalog = catalog }

    public var body: some View {
        TabView(selection: $selection) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) { GeneralSettings() }
            Tab("Agents", systemImage: "cpu", value: SettingsTab.agents) {
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

/// The tab Settings shows. It is stored, so that `Manage Agents…` can choose it before the window opens.
enum SettingsTab: String {
    case general, agents

    static let defaultsKey = "settingsTab"

    /// The tab stored in `defaults`; `general` when none or an unknown one is stored.
    static func stored(in defaults: UserDefaults = .standard) -> SettingsTab {
        defaults.string(forKey: defaultsKey).flatMap(SettingsTab.init) ?? .general
    }

    func store(in defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }
}

/// Opens Settings on the Agents tab.
struct ManageAgentsButton: View {
    var title = "Manage Agents…"
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(title) {
            SettingsTab.agents.store()
            openSettings()
        }
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
