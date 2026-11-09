import AgenthesiaCore
import SwiftUI

/// "Working for 1m 12s · 3 of 7 · Writing tests" directly above the composer card while a turn runs, "Waiting for
/// you" while a request is pending (ADR-0039 and its amendment).
struct WorkingTimeLine: View {
    let startedAt: Date
    /// A permission request or an input form blocks the turn.
    var waiting = false
    var plan: PlanProgress?

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            HStack(spacing: 6) {
                if waiting {
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(Self.text(elapsed: context.date.timeIntervalSince(startedAt), waiting: waiting, plan: plan))
                    .monospacedDigit().lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    static func text(elapsed: TimeInterval, waiting: Bool, plan: PlanProgress? = nil) -> String {
        if waiting { return "Waiting for you" }
        let working = "Working for \(WorkingDuration.format(elapsed))"
        return plan.map { "\(working) · \($0.summary)" } ?? working
    }
}
