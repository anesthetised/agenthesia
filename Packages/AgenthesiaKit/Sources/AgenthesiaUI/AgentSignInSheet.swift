import ACP
import AgenthesiaCore
import SwiftUI

/// Account setup without a session, with the terminal occupying the same sheet (ADR-0038).
struct AgentSignInSheet: View {
    let flow: AgentSignIn
    let onDone: () -> Void

    var body: some View {
        Group {
            if let terminal = flow.terminal {
                SignInTerminalSheet(terminal: terminal, onDone: finishTerminal)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Sign in to \(flow.name)").font(.headline)
                    switch flow.state {
                    case .idle, .initializing:
                        ProgressView("Getting sign-in methods…")
                    case .ready:
                        SignInMethods(methods: flow.methods, pending: nil, onSignIn: signIn, onCancel: onDone)
                    case .signingIn(let id):
                        SignInMethods(methods: flow.methods, pending: id, onSignIn: signIn, onCancel: onDone)
                    case .completed:
                        Label("Sign-in completed", systemImage: "checkmark.circle")
                        Text("The agent may ask you to sign in again when you start a session.")
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                        Button("Retry", action: retry)
                    case .closing:
                        ProgressView("Stopping…")
                    case .closed:
                        Text("Sign-in cancelled.").foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button(doneTitle, action: onDone)
                            .keyboardShortcut(.cancelAction)
                            .disabled(flow.state == .closing)
                    }
                }
                .padding(20)
                .frame(width: 500)
            }
        }
        .interactiveDismissDisabled()
        .task { await flow.prepare() }
    }

    private var doneTitle: String {
        switch flow.state {
        case .completed, .failed, .closed: "Done"
        default: "Cancel"
        }
    }

    private func signIn(_ id: ACP.AuthMethodID) { Task { await flow.signIn(with: id) } }
    private func retry() { Task { await flow.prepare() } }
    private func finishTerminal() {
        if case .failed = flow.state { flow.dismissTerminal() } else { onDone() }
    }
}
