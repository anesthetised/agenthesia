import ACP
import AgenthesiaCore
import AppKit
import SwiftUI
import Testing

@testable import AgenthesiaUI

@MainActor @Suite struct PlanSectionTests {
    @Test func planRowsShowStatusAndPriority() {
        #expect(PlanRow.symbol(.completed) == "checkmark")
        #expect(PlanRow.symbol(.inProgress) == "circle.fill")
        #expect(PlanRow.symbol(.pending) == "circle" && PlanRow.symbol(.unknown("blocked")) == "circle")
        #expect(PlanRow.priority(.high) == "High priority")
        #expect(PlanRow.priority(.unknown("urgent")) == "Urgent priority")
        let entry = ACP.PlanEntry(content: "Write tests", priority: .medium, status: .inProgress)
        #expect(PlanRow.accessibilityLabel(entry) == "In progress: Write tests, medium priority")
        #expect(
            PlanRow.accessibilityLabel(.init(content: "a", priority: .low, status: .completed))
                == "Done: a, low priority"
        )
    }
}

/// The section in the inspector's grouped form: open while the turn runs, its header alone once it ended.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PlanSectionHostingTests {
    private func height(running: Bool) async -> CGFloat {
        let plan = ACP.Plan(
            entries: ["Read", "Write", "Test", "Document"].map {
                .init(content: $0, priority: .medium, status: $0 == "Read" ? .completed : .pending)
            }
        )
        let progress = PlanProgress(plan)
        let host = NSHostingView(
            rootView: Form { progress.map { PlanSection(plan: plan, progress: $0, running: running) } }
                .formStyle(.grouped)
        )
        host.frame = .init(x: 0, y: 0, width: 320, height: 600)
        let window = OffscreenWindow(size: host.frame.size)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        return host.fittingSize.height - host.safeAreaInsets.top
    }

    @Test func theSectionCollapsesToItsHeaderOnceTheTurnEnded() async {
        let open = await height(running: true)
        let collapsed = await height(running: false)
        // Four rows of at least a line each go away.
        #expect(open - collapsed > 4 * 16)
    }
}
