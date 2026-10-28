import ACP
import AgenthesiaCore
import SwiftUI

/// The agent's sign-in methods, shown in place of the composer while the session waits for sign-in (ADR-0033).
struct SignInPanel: View {
    let agentName: String
    let signIn: LiveSession.SignIn
    /// Whether a saved session is being continued rather than a new one started.
    let continuing: Bool
    let onSignIn: (ACP.AuthMethodID) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in to \(agentName)").font(.headline)
                Text(
                    continuing
                        ? "The agent needs you to sign in before the session can continue."
                        : "The agent needs you to sign in before the session can start."
                )
                .foregroundStyle(.secondary)
            }
            if let message = signIn.message {
                Label(message, systemImage: "exclamationmark.triangle").textSelection(.enabled)
            }
            SignInMethods(methods: signIn.methods, pending: signIn.pending, onSignIn: onSignIn, onCancel: onCancel)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
