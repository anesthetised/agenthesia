import AgenthesiaUI
import SwiftUI

@main
struct AgenthesiaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        #if DEBUG
            .commands { RenderingLabCommands() }
        #endif

        #if DEBUG
            Window("Rendering Lab", id: RenderingLabView.windowID) {
                RenderingLabView()
            }
            .defaultLaunchBehavior(RenderingLabView.isAutorun ? .presented : .automatic)
        #endif
    }
}
