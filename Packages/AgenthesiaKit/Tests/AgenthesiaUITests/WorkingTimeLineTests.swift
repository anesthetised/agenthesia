import Foundation
import Testing

@testable import AgenthesiaUI

@Suite struct WorkingTimeLineTests {
    @Test func theLineCountsTheTurnWhileTheAgentWorks() {
        #expect(WorkingTimeLine.text(elapsed: 1, waiting: false) == "Working for 1s")
        #expect(WorkingTimeLine.text(elapsed: 72, waiting: false) == "Working for 1m 12s")
    }

    @Test func theLineSaysWhenTheAgentWaitsForTheUser() {
        #expect(WorkingTimeLine.text(elapsed: 1, waiting: true) == "Waiting for you")
        #expect(WorkingTimeLine.text(elapsed: 3700, waiting: true) == "Waiting for you")
    }
}
