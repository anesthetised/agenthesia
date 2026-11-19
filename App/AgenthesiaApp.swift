import AgenthesiaUI
import SwiftUI

@main
struct AgenthesiaApp: App {
    @NSApplicationDelegateAdaptor(SessionApplicationDelegate.self) private var lifecycle

    #if DEBUG
        init() { RenderingLabView.failUnlessAutorunStarts() }
    #endif

    var body: some Scene {
        WindowGroup(for: WindowTarget.self) { $target in
            RootView(sessions: lifecycle.sessions, catalog: .shared, target: $target)
        } defaultValue: {
            .launch
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            FileCommands(); SessionCommands()
        }
        #if DEBUG
            .commands { RenderingLabCommands() }
            // An unattended lab run (`AGENTHESIA_LAB_RUNS`) shows only the Rendering Lab and restores no window.
            .defaultLaunchBehavior(RenderingLabView.isAutorun ? .suppressed : .automatic)
            .restorationBehavior(RenderingLabView.isAutorun ? .disabled : .automatic)
        #endif

        MenuBarExtra {
            SessionMenuBarContent(sessions: lifecycle.sessions)
        } label: {
            SessionMenuBarLabel(sessions: lifecycle.sessions)
        }

        Settings {
            SettingsView(catalog: .shared)
        }

        #if DEBUG
            Window("Rendering Lab", id: RenderingLabView.windowID) {
                RenderingLabView()
            }
            .defaultLaunchBehavior(RenderingLabView.isAutorun ? .presented : .automatic)
            .restorationBehavior(RenderingLabView.isAutorun ? .disabled : .automatic)
        #endif
    }
}
