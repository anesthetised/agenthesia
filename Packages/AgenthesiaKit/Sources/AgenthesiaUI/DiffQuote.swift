import Rendering

/// The text Ask agent puts in the composer for lines selected in a review diff (ADR-0041).
enum DiffQuote {
    /// `lines` as a quote of the file at `path`, or `nil` when they hold no diff line (a selection of hunk headers).
    ///
    /// The first line names the new file's line ranges, `42-44, 60`; lines that were only removed, with no kept or added
    /// line beside them, say `42 (removed)` for the line that follows them. Hunk headers are left out, as the ranges
    /// already tell the hunks apart. The lines follow in a `diff` fence. `stale` marks a quote taken from a diff the
    /// file has since moved on from.
    nonisolated static func make(path: String, lines: [DiffLine], stale: Bool = false) -> String? {
        let lines = lines.filter { $0.kind != .hunk }
        guard !lines.isEmpty else { return nil }
        var ranges: [ClosedRange<Int>] = []
        for number in lines.compactMap(\.newNumber) {
            if let last = ranges.last, number == last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...number
            } else {
                ranges.append(number...number)
            }
        }
        // A removed line is covered by a range that holds the line after it, or ends on the line before it.
        let removed = Set(lines.filter { $0.kind == .removed }.map(\.newPosition)).filter { position in
            !ranges.contains { $0.lowerBound <= position && position <= $0.upperBound + 1 }
        }
        let places =
            (ranges.map {
                (
                    $0.lowerBound,
                    $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)"
                )
            }
            + removed.map { ($0, "\($0) (removed)") }).sorted { $0.0 < $1.0 }.map(\.1)
        let body = lines.map { line in
            let mark: Character =
                switch line.kind {
                case .added: "+"
                case .removed: "-"
                case .context, .hunk: " "
                }
            return "\(mark)\(line.text)"
        }.joined(separator: "\n")
        let quote =
            "`\(path):\(places.joined(separator: ", "))`\n\(LiveTranscriptSource.fenced(body, language: "diff"))"
        return stale ? quote + "\n(from an earlier version; lines may have moved)" : quote
    }
}
