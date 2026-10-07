public import SwiftUI

/// The main window's temporary demo interface.
public struct RootView: View {
    @State private var session = DemoSession()
    @State private var prompt = ""
    @State private var selectedSession: String? = "demo"
    @FocusState private var composerFocused: Bool

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedSession) {
                Section("Demo project") {
                    Label("Demo session", systemImage: "bubble.left.and.bubble.right")
                        .tag("demo")
                }
            }
            .navigationTitle("Agenthesia")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                Label("Local preview · not saved", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        } detail: {
            VStack(spacing: 0) {
                DemoTranscript(session: session)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Ask the demo assistant…", text: $prompt, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.plain)
                        .focused($composerFocused)
                        .onSubmit(send)
                        .accessibilityLabel("Demo prompt")
                    HStack {
                        Text(
                            session.isStreaming
                                ? "Demo is streaming · send after it finishes" : "Demo only · no agent connected"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        if session.isStreaming {
                            Button("Stop", systemImage: "stop.fill", action: session.stop)
                                .keyboardShortcut(".", modifiers: .command)
                        } else {
                            Button("Send", systemImage: "arrow.up", action: send)
                                .keyboardShortcut(.return, modifiers: .command)
                                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding(16)
                .background(.bar)
            }
            .navigationTitle("Demo session")
            .navigationSubtitle("Temporary preview")
            .toolbar {
                ToolbarItem {
                    Label(
                        session.isStreaming ? "Streaming" : "Demo",
                        systemImage: session.isStreaming ? "ellipsis" : "sparkles"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear { composerFocused = true }
        .onDisappear { session.stop() }
    }

    private func send() {
        guard !session.isStreaming, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.send(prompt)
        prompt = ""
        composerFocused = true
    }
}

#Preview {
    RootView()
}
