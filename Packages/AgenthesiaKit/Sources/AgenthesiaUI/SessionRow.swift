import AgenthesiaCore
import SwiftUI

/// A sidebar row: project badge, title and project, status symbol and relative start time (ADR-0039).
struct SessionRow: View {
    let title: String
    let project: String?
    let outcome: WorktreeOutcome?
    /// Nil for saved sessions, which have no live status.
    let activity: LiveSession.Activity?
    /// Nil while a starting session has no record yet.
    let started: Date?

    var body: some View {
        HStack {
            ProjectBadgeView(name: project)
            VStack(alignment: .leading) {
                Text(title).lineLimit(1)
                if let subtitle = Self.subtitle(project: project, outcome: outcome) {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let activity { StatusIcon(activity: activity) }
            if let started {
                TimelineView(.everyMinute) { context in
                    Text(RelativeTime.short(from: started, to: context.date))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.accessibilityLabel(
                title: title,
                subtitle: Self.subtitle(project: project, outcome: outcome),
                status: activity,
                started: started
            )
        )
    }

    /// The project name, followed by ` · Merged` or ` · Discarded` for a finished worktree.
    static func subtitle(project: String?, outcome: WorktreeOutcome?) -> String? {
        let parts = [project, outcome?.label].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func accessibilityLabel(
        title: String,
        subtitle: String?,
        status: LiveSession.Activity?,
        started: Date?,
        now: Date = .now
    ) -> String {
        [
            title, subtitle, status.flatMap { $0 == .idle ? nil : $0.rawValue },
            started.map { RelativeTime.short(from: $0, to: now) },
        ]
        .compactMap(\.self).joined(separator: ", ")
    }
}
