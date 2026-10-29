import CoreGraphics

/// The centered column that the transcript rows and the composer card share (ADR-0039).
enum TranscriptColumn {
    static let maxWidth: CGFloat = 720
    static let minMargin: CGFloat = 24

    /// The column's width in a row of `rowWidth`: at most `maxWidth`, leaving `minMargin` on each side.
    static func width(inRowOfWidth rowWidth: CGFloat) -> CGFloat {
        max(0, min(maxWidth, rowWidth - 2 * minMargin))
    }

    /// The column's leading edge in a row of `rowWidth`.
    static func minX(inRowOfWidth rowWidth: CGFloat) -> CGFloat {
        max(0, (rowWidth - width(inRowOfWidth: rowWidth)) / 2)
    }

    /// A user bubble is at most this fraction of the column wide.
    static let bubbleMaxFraction: CGFloat = 0.8
    static let bubbleRadius: CGFloat = 14
    static let bubblePadding = CGSize(width: 14, height: 10)

    /// The widest a bubble gets in a column of `columnWidth`.
    static func bubbleMaxWidth(inColumnOfWidth columnWidth: CGFloat) -> CGFloat { bubbleMaxFraction * columnWidth }

    /// The bubble's width for text of `textWidth` at its natural width: the text and its padding, but at most
    /// `bubbleMaxWidth`.
    static func bubbleWidth(forTextWidth textWidth: CGFloat, inColumnOfWidth columnWidth: CGFloat) -> CGFloat {
        min(max(0, textWidth) + 2 * bubblePadding.width, bubbleMaxWidth(inColumnOfWidth: columnWidth))
    }
}
