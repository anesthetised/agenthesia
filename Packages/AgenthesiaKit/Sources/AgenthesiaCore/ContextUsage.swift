public import ACP
import Foundation

/// The agent's context window as the window shows it (ADR-0039's amendment): the inspector's rows and the composer's
/// ring, which appears only from 70 % and turns to the attention color from 90 %.
public struct ContextUsage: Equatable, Sendable {
    public enum Ring: Equatable, Sendable { case hidden, normal, attention }

    public let used: Int
    public let size: Int
    public let cost: ACP.Cost?

    /// Nil before the first `usage_update` and for a window of no size.
    public init?(_ usage: ACP.UsageUpdate?) {
        guard let usage, usage.size > 0 else { return nil }
        used = max(usage.used, 0)
        size = usage.size
        cost = usage.cost
    }

    public var fraction: Double { Double(used) / Double(size) }

    /// Rounded down, so the ring does not claim a threshold before it is reached.
    public var percent: Int { used * 100 / size }

    public var ring: Ring { percent >= 90 ? .attention : percent >= 70 ? .normal : .hidden }

    /// `84k of 200k · 42 %`.
    public var summary: String { "\(Self.tokens(used)) of \(Self.tokens(size)) · \(percent) %" }

    /// The cost in the agent's currency, formatted by the system: `$1.23`.
    public var costText: String? { cost.map { $0.amount.formatted(.currency(code: $0.currency)) } }

    /// `950`, `84k`, `1M`, `1.5M`.
    static func tokens(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        let thousands = Int((Double(count) / 1000).rounded())
        if thousands < 1000 { return "\(thousands)k" }
        let millions = (Double(count) / 100_000).rounded() / 10
        return millions == millions.rounded() ? "\(Int(millions))M" : "\(millions)M"
    }
}
