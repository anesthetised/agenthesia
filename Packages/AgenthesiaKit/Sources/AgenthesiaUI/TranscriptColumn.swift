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
}
