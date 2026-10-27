import AgenthesiaUI
import SwiftUI

@main
struct AgenthesiaApp: App {
    @NSApplicationDelegateAdaptor(SessionApplicationDelegate.self) private var lifecycle

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
        #endif

        Settings {
            SettingsView(catalog: .shared)
        }

        #if DEBUG
            Window("Rendering Lab", id: RenderingLabView.windowID) {
                RenderingLabView()
            }
            .defaultLaunchBehavior(RenderingLabView.isAutorun ? .presented : .automatic)
        #endif
    }
}
