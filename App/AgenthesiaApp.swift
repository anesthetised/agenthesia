import AgenthesiaUI
import SwiftUI

@main
struct AgenthesiaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1000, height: 700)
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
