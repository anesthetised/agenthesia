import AgenthesiaCore
import SwiftUI

/// A sidebar row: project badge, title, `project · reason`, status symbol and the time of the last activity
/// (ADR-0039).
struct SessionRow: View {
    let title: String
    let project: String?
    /// What the session waits for, or how it finished; nil when the symbol says it.
    let reason: String?
    /// Nil for saved sessions, which have no live status.
    let activity: LiveSession.Activity?
    /// Nil while a starting session has no record yet.
    let lastActivity: Date?

    var body: some View {
        HStack {
            ProjectBadgeView(name: project)
            VStack(alignment: .leading) {
                Text(title).lineLimit(1)
                if project != nil || reason != nil {
                    SubtitleLayout {
                        if let project { Text(project).lineLimit(1) }
                        if let reason { Text(project == nil ? reason : " · \(reason)").lineLimit(1) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let activity { StatusIcon(activity: activity) }
            if let lastActivity {
                TimelineView(.everyMinute) { context in
                    Text(RelativeTime.short(from: lastActivity, to: context.date))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .contentShape(.rect)
        .help(Self.tooltip(title: title, project: project, reason: reason))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.accessibilityLabel(
                title: title,
                project: project,
                reason: reason,
                status: activity,
                lastActivity: lastActivity
            )
        )
    }

    /// The project and the reason on one line.
    static func subtitle(project: String?, reason: String?) -> String? {
        let parts = [project, reason].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The untruncated text of the row.
    static func tooltip(title: String, project: String?, reason: String?) -> String {
        [title, subtitle(project: project, reason: reason)].compactMap(\.self).joined(separator: "\n")
    }

    /// `title, project, reason, last active 3m`; a row without a reason names its status instead.
    static func accessibilityLabel(
        title: String,
        project: String?,
        reason: String?,
        status: LiveSession.Activity?,
        lastActivity: Date?,
        now: Date = .now
    ) -> String {
        [
            title, project, reason ?? status.flatMap { $0 == .idle ? nil : $0.rawValue },
            lastActivity.map { "last active \(RelativeTime.short(from: $0, to: now))" },
        ]
        .compactMap(\.self).joined(separator: ", ")
    }
}

/// The project and the reason side by side on one line. When they do not fit, the project gives way first, down to
/// 40 % of the line; then the reason is cut at its tail (ADR-0039).
struct SubtitleLayout: Layout {
    static let projectShare = 0.4

    /// The widths of the project and the reason on a line `available` wide.
    static func widths(project: Double, reason: Double, available: Double) -> (project: Double, reason: Double) {
        guard project + reason > available else { return (project, reason) }
        let projectWidth = min(project, max(available - reason, available * projectShare))
        return (projectWidth, min(reason, available - projectWidth))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = ideals.reduce(0) { $0 + $1.width }
        return CGSize(width: min(natural, proposal.width ?? natural), height: ideals.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        var widths = ideals.map { min($0, bounds.width) }
        if ideals.count == 2 {
            let fitted = Self.widths(project: ideals[0], reason: ideals[1], available: bounds.width)
            widths = [fitted.project, fitted.reason]
        }
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width
        }
    }
}
