import CoreGraphics

/// Which panes of the detail column fit beside each other, and how wide each is (ADR-0039, amendments 2026-10-30).
///
/// The transcript always stays. The file pane the user opened comes next, and the inspector gives way first, so
/// at the 740 pt window minimum the inspector is hidden while a file is open. A hidden pane keeps its state and
/// returns when the window is wide enough.
struct DetailPanes: Equatable {
    static let transcriptMinWidth: CGFloat = 240
    static let filePaneMinWidth: CGFloat = 240
    static let inspectorMinWidth: CGFloat = 220
    static let inspectorMaxWidth: CGFloat = 360

    let width: CGFloat
    let showsFilePane: Bool
    let showsInspector: Bool

    /// Pane widths in points; a hidden pane is 0 and the three always add up to the column's width.
    struct Widths: Equatable {
        var transcript: CGFloat
        var filePane: CGFloat
        var inspector: CGFloat
    }

    /// `width` is the detail column's width; `filePane` and `inspector` say what the user asked for.
    init(width: CGFloat, filePane: Bool, inspector: Bool) {
        self.width = width
        showsFilePane = filePane && width >= Self.transcriptMinWidth + Self.filePaneMinWidth
        let used = Self.transcriptMinWidth + (showsFilePane ? Self.filePaneMinWidth : 0)
        showsInspector = inspector && width >= used + Self.inspectorMinWidth
    }

    /// Splits the column from the widths the user last chose (by dragging, or the defaults). The transcript gives
    /// way first; below the preferred sizes the file pane shrinks to its minimum, then the inspector.
    func widths(filePane preferredFile: CGFloat, inspector preferredInspector: CGFloat) -> Widths {
        var file = showsFilePane ? max(preferredFile, Self.filePaneMinWidth) : 0
        var inspector =
            showsInspector
            ? min(max(preferredInspector, Self.inspectorMinWidth), Self.inspectorMaxWidth) : 0
        let room = width - Self.transcriptMinWidth
        if file + inspector > room {
            if showsFilePane { file = max(Self.filePaneMinWidth, room - inspector) }
            if showsInspector { inspector = max(Self.inspectorMinWidth, min(inspector, room - file)) }
        }
        return Widths(transcript: width - file - inspector, filePane: file, inspector: inspector)
    }
}
