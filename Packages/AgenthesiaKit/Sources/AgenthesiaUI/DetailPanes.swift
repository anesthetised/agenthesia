import CoreGraphics

/// Which panes of the detail column fit beside each other (ADR-0039, amendment 2026-10-30).
///
/// The transcript always stays. The file pane the user opened comes next, and the inspector gives way first, so
/// at the 740 pt window minimum the inspector is hidden while a file is open. A hidden pane keeps its state and
/// returns when the window is wide enough.
struct DetailPanes: Equatable {
    static let transcriptMinWidth: CGFloat = 240
    static let filePaneMinWidth: CGFloat = 240
    static let inspectorMinWidth: CGFloat = 220

    let showsFilePane: Bool
    let showsInspector: Bool

    /// `width` is the detail column's width; `filePane` and `inspector` say what the user asked for.
    init(width: CGFloat, filePane: Bool, inspector: Bool) {
        showsFilePane = filePane && width >= Self.transcriptMinWidth + Self.filePaneMinWidth
        let used = Self.transcriptMinWidth + (showsFilePane ? Self.filePaneMinWidth : 0)
        showsInspector = inspector && width >= used + Self.inspectorMinWidth
    }
}
