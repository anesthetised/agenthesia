import ACP
import Foundation
import Testing

@testable import AgenthesiaCore

@Suite struct ContextUsageTests {
    private func usage(_ used: Int, of size: Int = 200_000, cost: ACP.Cost? = nil) -> ContextUsage? {
        ContextUsage(.init(used: used, size: size, cost: cost))
    }

    @Test func nothingBeforeTheFirstUpdateOrForAnEmptyWindow() {
        #expect(ContextUsage(nil) == nil)
        #expect(usage(10, of: 0) == nil)
    }

    @Test func theRingAppearsFrom70AndTurnsToAttentionFrom90Percent() {
        #expect(usage(139_999)?.ring == .hidden)
        #expect(usage(140_000)?.ring == .normal)
        #expect(usage(179_999)?.ring == .normal)
        #expect(usage(180_000)?.ring == .attention)
        #expect(usage(250_000)?.ring == .attention)
        #expect(usage(0)?.ring == .hidden)
    }

    @Test func thePercentageIsRoundedDown() {
        #expect(usage(139_999)?.percent == 69)
        #expect(usage(-5)?.percent == 0)
    }

    @Test func theSummaryNamesTokensInThousandsAndMillions() {
        #expect(usage(84_000)?.summary == "84k of 200k · 42 %")
        #expect(usage(950, of: 1000)?.summary == "950 of 1k · 95 %")
        #expect(usage(999_600, of: 1_000_000)?.summary == "1M of 1M · 99 %")
        #expect(usage(84_400, of: 1_500_000)?.summary == "84k of 1.5M · 5 %")
    }

    @Test func theCostIsFormattedInTheAgentsCurrency() {
        let dollars = ACP.Cost(amount: 1.23, currency: "USD")
        #expect(usage(1, cost: dollars)?.costText == 1.23.formatted(.currency(code: "USD")))
        #expect(usage(1, cost: .init(amount: 2, currency: "EUR"))?.costText == 2.0.formatted(.currency(code: "EUR")))
        #expect(usage(1)?.costText == nil)
    }
}
