import ACP
import AgenthesiaCore
import AppKit
import SwiftUI
import Testing

@testable import AgenthesiaUI

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ContextRingTests {
    private func usage(_ used: Int, cost: ACP.Cost? = nil) throws -> ContextUsage {
        try #require(ContextUsage(.init(used: used, size: 200_000, cost: cost)))
    }

    @Test func theLabelCarriesTheNumbersAndTheCost() throws {
        #expect(ContextRing.label(try usage(150_000)) == "Context 150k of 200k · 75 %")
        let cost = ACP.Cost(amount: 1.5, currency: "USD")
        let label = ContextRing.label(try usage(150_000, cost: cost))
        #expect(label == "Context 150k of 200k · 75 %, cost \(1.5.formatted(.currency(code: "USD")))")
    }

    /// Below 70 % the ring takes no room, so the pills keep the row.
    @Test func theRingTakesRoomOnlyFrom70Percent() async throws {
        func width(_ used: Int) async throws -> CGFloat {
            let host = NSHostingView(rootView: ContextRing(usage: try usage(used)))
            let window = OffscreenWindow(size: .init(width: 200, height: 40))
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            for _ in 0..<5 { await Task.yield(); host.layoutSubtreeIfNeeded() }
            return host.fittingSize.width
        }
        #expect(try await width(100_000) == 0)
        #expect(try await width(150_000) > 20)
    }
}
