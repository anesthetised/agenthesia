import SwiftUI

/// `New response below`: the transcript's end changed while the reader was away from it (ADR-0026's amendment).
/// Shown at the transcript's bottom edge; its appearance is not announced, to stay calm during streaming.
struct NewResponseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("New response below", systemImage: "arrow.down")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background(.bar, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.bottom, 12)
        .help("Jump to Latest (⌥⌘↓)")
    }
}
