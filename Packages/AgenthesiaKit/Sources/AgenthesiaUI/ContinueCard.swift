import AgenthesiaCore
import SwiftUI

/// Replaces the composer card for a session that cannot take a prompt (ADR-0039): the state, and Continue when the
/// session can be reattached.
struct ContinueCard: View {
    /// What the card says. Nil from `init` when the session accepts prompts and the composer is shown.
    struct State: Equatable {
        let title: String
        let symbol: String
        let showsContinue: Bool

        init?(status: SessionController.Status, isMerging: Bool, outcome: WorktreeOutcome?, canContinue: Bool) {
            switch (outcome, status) {
            case (.merged, _): (title, symbol) = ("Merged · read-only", "checkmark.circle")
            case (.discarded, _): (title, symbol) = ("Discarded · read-only", "trash")
            case _ where isMerging: (title, symbol) = ("Merging…", "arrow.triangle.merge")
            case (_, .readOnly): (title, symbol) = ("Saved session", "clock.arrow.circlepath")
            case (_, .failed): (title, symbol) = ("Connection failed", "exclamationmark.triangle")
            case (_, .closed): (title, symbol) = ("Session ended", "stop.circle")
            case (_, .ready), (_, .starting): (title, symbol) = ("Starting…", "hourglass")
            case (_, .idle), (_, .running), (_, .stopping): return nil
            }
            showsContinue = outcome == nil && canContinue
        }
    }

    let state: State
    let onContinue: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(state.title, systemImage: state.symbol).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if state.showsContinue {
                Button("Continue", systemImage: "play.fill", action: onContinue)
                    .buttonStyle(.borderedProminent).help("Reconnect to the agent.")
            }
        }
        .padding(12)
        .background(.bar, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator) }
    }
}
