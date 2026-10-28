import ACP
import SwiftUI

/// The same advertised methods in a session and in Settings.
struct SignInMethods: View {
    let methods: [ACP.AuthMethod]
    let pending: ACP.AuthMethodID?
    let onSignIn: (ACP.AuthMethodID) -> Void
    let onCancel: () -> Void

    var body: some View {
        let rows = SignInMethodRow.rows(methods)
        if rows.isEmpty {
            Text("This agent offers no sign-in methods. If sign-in is needed, follow its setup instructions.")
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
                if pending == row.id {
                    ProgressView().controlSize(.small).accessibilityLabel("Signing in")
                    Button("Cancel", action: onCancel)
                } else {
                    Button(row.opensTerminal ? "Sign In…" : "Sign In") { onSignIn(row.id) }
                        .disabled(pending != nil || !row.isSupported)
                        .accessibilityLabel("Sign in with \(row.name)")
                }
            }
        }
    }
}
