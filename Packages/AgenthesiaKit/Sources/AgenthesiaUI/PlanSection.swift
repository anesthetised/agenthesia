import ACP
import AgenthesiaCore
import SwiftUI

/// The agent's plan, leading the inspector (ADR-0039's amendment): open while the turn runs, collapsed to its header
/// `Plan · 7 of 7` once it ended. The user's toggle holds until the turn starts or ends.
struct PlanSection: View {
    let plan: ACP.Plan
    let progress: PlanProgress
    let running: Bool
    @State private var isExpanded: Bool

    init(plan: ACP.Plan, progress: PlanProgress, running: Bool) {
        self.plan = plan
        self.progress = progress
        self.running = running
        _isExpanded = State(initialValue: running)
    }

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(Array(plan.entries.enumerated()), id: \.offset) { PlanRow(entry: $0.element) }
        } header: {
            Text("Plan · \(progress.completed) of \(progress.total)")
        }
        .onChange(of: running) { isExpanded = running }
    }
}

/// One plan entry: its status as a symbol, the text in full, dimmed once completed; the priority is not drawn.
struct PlanRow: View {
    let entry: ACP.PlanEntry

    var body: some View {
        Label {
            Text(entry.content)
        } icon: {
            Image(systemName: Self.symbol(entry.status))
                .foregroundStyle(entry.status == .inProgress ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .foregroundStyle(entry.status == .completed ? .secondary : .primary)
        .help(Self.priority(entry.priority))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(entry))
    }

    static func symbol(_ status: ACP.PlanEntryStatus) -> String {
        switch status {
        case .completed: "checkmark"
        case .inProgress: "circle.fill"
        default: "circle"
        }
    }

    static func priority(_ priority: ACP.PlanEntryPriority) -> String {
        "\(priority.rawValue.prefix(1).uppercased())\(priority.rawValue.dropFirst()) priority"
    }

    static func accessibilityLabel(_ entry: ACP.PlanEntry) -> String {
        let status =
            switch entry.status {
            case .completed: "Done"
            case .inProgress: "In progress"
            default: "Pending"
            }
        return "\(status): \(entry.content), \(priority(entry.priority).lowercased())"
    }
}
