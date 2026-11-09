import ACP
import AgenthesiaCore
import Foundation
import Testing

@testable import AgenthesiaUI

@MainActor @Suite struct WorkingTimeLineTests {
    @Test func theLineCountsTheTurnWhileTheAgentWorks() {
        #expect(WorkingTimeLine.text(elapsed: 1, waiting: false) == "Working for 1s")
        #expect(WorkingTimeLine.text(elapsed: 72, waiting: false) == "Working for 1m 12s")
    }

    @Test func theLineFollowsThePlan() {
        func plan(_ statuses: [ACP.PlanEntryStatus]) -> PlanProgress? {
            PlanProgress(.init(entries: statuses.map { .init(content: "Writing tests", priority: .low, status: $0) }))
        }
        #expect(
            WorkingTimeLine.text(elapsed: 72, waiting: false, plan: plan([.completed, .inProgress, .pending]))
                == "Working for 1m 12s · 1 of 3 · Writing tests"
        )
        #expect(
            WorkingTimeLine.text(elapsed: 72, waiting: false, plan: plan([.completed, .pending]))
                == "Working for 1m 12s · 1 of 2 done"
        )
        #expect(WorkingTimeLine.text(elapsed: 72, waiting: true, plan: plan([.inProgress])) == "Waiting for you")
    }

    @Test func theLineSaysWhenTheAgentWaitsForTheUser() {
        #expect(WorkingTimeLine.text(elapsed: 1, waiting: true) == "Waiting for you")
        #expect(WorkingTimeLine.text(elapsed: 3700, waiting: true) == "Waiting for you")
    }
}
