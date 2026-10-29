import CoreGraphics
import Testing

@testable import AgenthesiaUI

@MainActor struct TranscriptColumnTests {
    @Test func wideRowsGetACenteredColumnOfAtMost720Points() {
        #expect(TranscriptColumn.width(inRowOfWidth: 1200) == 720)
        #expect(TranscriptColumn.minX(inRowOfWidth: 1200) == 240)
        #expect(TranscriptColumn.width(inRowOfWidth: 768) == 720)
        #expect(TranscriptColumn.minX(inRowOfWidth: 768) == 24)
    }

    @Test func narrowRowsKeepTheMarginsOnBothSides() {
        #expect(TranscriptColumn.width(inRowOfWidth: 500) == 452)
        #expect(TranscriptColumn.minX(inRowOfWidth: 500) == 24)
        #expect(TranscriptColumn.width(inRowOfWidth: 767) == 719)
    }

    @Test func degenerateRowsNeverGoNegative() {
        for width in [0, 10, 48, -5] as [CGFloat] {
            #expect(TranscriptColumn.width(inRowOfWidth: width) == 0)
            #expect(TranscriptColumn.minX(inRowOfWidth: width) >= 0)
        }
    }
}
