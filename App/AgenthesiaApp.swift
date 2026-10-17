import AgenthesiaUI
import SwiftUI

@main
struct AgenthesiaApp: App {
    @NSApplicationDelegateAdaptor(SessionApplicationDelegate.self) private var lifecycle

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1000, height: 700)
        .commands { FileCommands() }
        #if DEBUG
            .commands { RenderingLabCommands() }
        #endif

        Settings {
            SettingsView()
        }

        #if DEBUG
            Window("Rendering Lab", id: RenderingLabView.windowID) {
                RenderingLabView()
            }
            .defaultLaunchBehavior(RenderingLabView.isAutorun ? .presented : .automatic)
        #endif
    }
}
