import AgenthesiaCore
import SwiftUI

/// The project's initials on a rounded square tinted by the project name.
struct ProjectBadgeView: View {
    let name: String?

    /// Fixed order: the tint is `hash % count`, so reordering would recolor every badge.
    static let tints: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .teal]

    static func tint(for name: String) -> Color {
        tints[Int(ProjectBadge.hash(name) % UInt64(tints.count))]
    }

    var body: some View {
        let tint = name.map(Self.tint(for:)) ?? .secondary
        Text(name.map(ProjectBadge.initials(of:)) ?? "")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
            .background(tint.opacity(0.25), in: .rect(cornerRadius: 5))
            .accessibilityHidden(true)
    }
}
