import AgenthesiaCore
import SwiftUI

/// The project's initials on a rounded square tinted by the project name; a dashed square for sessions without a
/// project (ADR-0048).
struct ProjectBadgeView: View {
    let name: String?
    var isScratch = false

    /// Fixed order: the tint is `hash % count`, so reordering would recolor every badge.
    static let tints: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .teal]

    static func tint(for name: String) -> Color {
        tints[Int(ProjectBadge.hash(name) % UInt64(tints.count))]
    }

    var body: some View {
        Group {
            switch ProjectBadge.mark(name: name, isScratch: isScratch) {
            case .dashed:
                Image(systemName: "square.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
            case .initials(let initials):
                square(initials, tint: name.map(Self.tint(for:)) ?? .secondary)
            case .empty:
                square("", tint: .secondary)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private func square(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
            .background(tint.opacity(0.25), in: .rect(cornerRadius: 5))
    }
}
