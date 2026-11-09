import AgenthesiaCore
import SwiftUI

/// The composer's context ring (ADR-0039's amendment): a fixed slot before the Send options, shown from 70 %, in the
/// attention color from 90 %. The numbers are in its tooltip and accessibility label.
struct ContextRing: View {
    let usage: ContextUsage

    var body: some View {
        if usage.ring != .hidden {
            HStack(spacing: 4) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle().trim(from: 0, to: min(usage.fraction, 1))
                        .stroke(style: .init(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 14, height: 14)
                Text("\(usage.percent) %").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(usage.ring == .attention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .fixedSize()
            .help(Self.label(usage))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.label(usage))
        }
    }

    /// `Context 84k of 200k · 42 %`, then the cost when the agent reports one.
    static func label(_ usage: ContextUsage) -> String {
        let context = "Context \(usage.summary)"
        return usage.costText.map { "\(context), cost \($0)" } ?? context
    }
}
