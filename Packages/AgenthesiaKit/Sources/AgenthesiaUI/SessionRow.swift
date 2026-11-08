import AgenthesiaCore
import SwiftUI

/// A sidebar row: project badge, title, `project · reason`, status symbol and the time of the last activity
/// (ADR-0039); on the Working shelf, the state and its time instead.
struct SessionRow: View {
    let title: String
    let project: String?
    /// What the session waits for, or how it finished; nil when the symbol says it.
    let reason: String?
    /// Nil for saved sessions, which have no live status.
    let activity: LiveSession.Activity?
    /// Nil while a starting session has no record yet.
    let lastActivity: Date?
    /// A row on the Working shelf ends with `Working 1m 12s` or `Idle 20m` (`SessionSidebar.shelfTime`).
    var shelf = false
    /// When the running turn began; only a shelf row shows it.
    var turnStartedAt: Date?

    var body: some View {
        // A running shelf row counts seconds; the others tick every minute, so that the time and the accessibility
        // label agree. A `List` builds only the rows on screen, so only those tick.
        if shelf, let turnStartedAt {
            TimelineView(.periodic(from: turnStartedAt, by: 1)) { context in row(now: context.date) }
        } else {
            TimelineView(.everyMinute) { context in row(now: context.date) }
        }
    }

    private func row(now: Date) -> some View {
        let time =
            shelf
            ? SessionSidebar.shelfTime(
                activity: activity ?? .idle,
                turnStartedAt: turnStartedAt,
                lastActivity: lastActivity,
                now: now
            ) : lastActivity.map { RelativeTime.short(from: $0, to: now) }
        return HStack {
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
            if let time {
                Text(time).font(.caption).foregroundStyle(.secondary).monospacedDigit()
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
                lastActivity: shelf ? nil : lastActivity,
                shelfTime: shelf ? time : nil,
                now: now
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

    /// `title, project, reason, last active 3m`; a row without a reason names its status instead. A shelf row ends
    /// with its shelf time, which names the state: `title, project, Working 1m 12s`.
    static func accessibilityLabel(
        title: String,
        project: String?,
        reason: String?,
        status: LiveSession.Activity?,
        lastActivity: Date?,
        shelfTime: String? = nil,
        now: Date = .now
    ) -> String {
        [
            title, project, reason ?? (shelfTime != nil ? nil : status.flatMap { $0 == .idle ? nil : $0.rawValue }),
            shelfTime ?? lastActivity.map { "last active \(RelativeTime.short(from: $0, to: now))" },
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
            let proposal = ProposedViewSize(width: width, height: bounds.height)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: proposal)
            // A truncated text is narrower than its share; the next one follows the text, not the share.
            x += subview.sizeThatFits(proposal).width
        }
    }
}
