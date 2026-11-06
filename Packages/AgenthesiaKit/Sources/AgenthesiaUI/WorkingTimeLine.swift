import AgenthesiaCore
import SwiftUI

/// "Working for 1m 12s" under the transcript while a turn runs, "Waiting for you" while a request is pending
/// (ADR-0039).
struct WorkingTimeLine: View {
    let startedAt: Date
    /// A permission request or an input form blocks the turn.
    var waiting = false

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            HStack(spacing: 6) {
                if waiting {
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(Self.text(elapsed: context.date.timeIntervalSince(startedAt), waiting: waiting))
                    .monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }

    static func text(elapsed: TimeInterval, waiting: Bool) -> String {
        waiting ? "Waiting for you" : "Working for \(WorkingDuration.format(elapsed))"
    }
}
