public import Foundation
public import Persistence

/// When a session that is not live settles by itself (ADR-0050).
public enum SessionSettling {
    /// How long a session stays in the list without activity: seven days, no setting.
    public static let idlePeriod: TimeInterval = 7 * 24 * 60 * 60

    /// Whether `session` settles now. A settled or live session never does; another one does when `lastOutcome`, the
    /// worktree's outcome recorded as the session's last event, exists, or when its last activity (its start without
    /// one) is `idlePeriod` old. An Unsettle after the outcome is a later event, so the seven days decide then.
    /// Archived sessions follow the same rule, so that Unarchive returns them to where `settledAt` says.
    public static func settles(
        _ session: SessionRecord,
        isLive: Bool,
        lastOutcome: WorktreeOutcome?,
        lastActivity: Date?,
        now: Date = .now
    ) -> Bool {
        guard session.settledAt == nil, !isLive else { return false }
        return lastOutcome != nil || now.timeIntervalSince(lastActivity ?? session.createdAt) >= idlePeriod
    }
}
