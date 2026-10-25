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
            let rows = SignInMethodRow.rows(signIn.methods)
            if rows.isEmpty {
                Text(
                    "The agent offers no way to sign in from here. Sign in to it in a terminal, then start a new session."
                )
                .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        if let detail = row.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if signIn.pending == row.id {
                        ProgressView().controlSize(.small).accessibilityLabel("Signing in")
                        Button("Cancel", action: onCancel)
                    } else {
                        Button(row.opensTerminal ? "Sign In…" : "Sign In") { onSignIn(row.id) }
                            .disabled(signIn.pending != nil || !row.isSupported)
                            .accessibilityLabel("Sign in with \(row.name)")
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
