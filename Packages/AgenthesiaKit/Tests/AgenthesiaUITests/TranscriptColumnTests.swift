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

    @Test func bubblesHugShortTextAndStopAtEightyPercentOfTheColumn() {
        #expect(TranscriptColumn.bubbleMaxWidth(inColumnOfWidth: 720) == 576)
        // Text and 14 pt padding on both sides.
        #expect(TranscriptColumn.bubbleWidth(forTextWidth: 100, inColumnOfWidth: 720) == 128)
        #expect(TranscriptColumn.bubbleWidth(forTextWidth: 548, inColumnOfWidth: 720) == 576)
        #expect(TranscriptColumn.bubbleWidth(forTextWidth: 5000, inColumnOfWidth: 720) == 576)
        #expect(TranscriptColumn.bubbleWidth(forTextWidth: 5000, inColumnOfWidth: 452) == 361.6)
        #expect(TranscriptColumn.bubbleWidth(forTextWidth: -3, inColumnOfWidth: 0) == 0)
    }
}
