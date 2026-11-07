import AgenthesiaCore
import SwiftUI
import Workspace

/// A changed file in the review's list: path, status, line counts and its viewed mark (ADR-0041).
struct ReviewFileRow: View {
    let change: SessionWorkspace.Review.Change
    /// Nil for a file without counts; `isBinary` says why when it is the reason.
    let lines: ChangeStats.Lines?
    let isBinary: Bool
    let isViewed: Bool
    let onToggleViewed: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(change.path).lineLimit(1).truncationMode(.middle)
                Text(change.status.rawValue).font(.caption).foregroundStyle(.secondary)
                if let previous = change.previousPath {
                    Text("From \(previous)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            .help(change.path)
            Spacer(minLength: 8)
            if isBinary {
                Text("binary").font(.caption).foregroundStyle(.secondary)
            } else if let lines {
                ChangeCounts(lines: lines).font(.caption)
            }
            Button(
                isViewed ? "Mark as Unviewed" : "Mark as Viewed",
                systemImage: isViewed ? "checkmark.circle.fill" : "circle",
                action: onToggleViewed
            )
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .foregroundStyle(isViewed ? Color.accentColor : .secondary)
            .help(isViewed ? "Mark as unviewed" : "Mark as viewed (⌥⌘V)")
        }
    }
}
