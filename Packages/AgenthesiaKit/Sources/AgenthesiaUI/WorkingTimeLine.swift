import AgenthesiaCore
import SwiftUI

/// "Working for 1m 12s" under the transcript while a turn runs (ADR-0039).
struct WorkingTimeLine: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Working for \(WorkingDuration.format(context.date.timeIntervalSince(startedAt)))")
                    .monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }
}
