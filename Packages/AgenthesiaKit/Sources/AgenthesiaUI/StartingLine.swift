import SwiftUI

/// `Fetching origin/main…` or `Starting Claude Code in a new worktree…`, directly above the `Starting…` card, as
/// `WorkingTimeLine` sits above the composer.
struct StartingLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).lineLimit(1)
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
