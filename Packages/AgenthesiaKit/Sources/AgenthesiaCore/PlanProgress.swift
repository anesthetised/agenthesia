public import ACP

/// How far the agent's plan has come: the entry it works on and the completed count (ADR-0039's amendment). The
/// status line, the sidebar and the inspector read it.
public struct PlanProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    /// The first entry in progress, reduced to one line like any sidebar reason.
    public let current: String?

    /// Nil without a plan or with an empty one.
    public init?(_ plan: ACP.Plan?) {
        guard let entries = plan?.entries, !entries.isEmpty else { return nil }
        completed = entries.count(where: { $0.status == .completed })
        total = entries.count
        current = entries.first { $0.status == .inProgress }.flatMap { SidebarReason.displayTitle($0.content) }
    }

    /// `3 of 7 · Writing tests` while an entry is in progress, `3 of 7 done` while none is.
    public var summary: String {
        let count = "\(completed) of \(total)"
        return current.map { "\(count) · \($0)" } ?? "\(count) done"
    }
}
