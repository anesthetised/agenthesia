public import SwiftUI

/// The main window's content.
public struct RootView: View {
    public init() {}

    public var body: some View {
        NavigationSplitView {
            List {}
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            ContentUnavailableView(
                "No Session",
                systemImage: "sparkles",
                description: Text("Start a session to begin.")
            )
        }
    }
}

#Preview {
    RootView()
}
