import AgenthesiaUI
import Foundation
import Rendering

/// Times linking inline code in finished agent rows against a file index (ADR-0025), next to rendering the same
/// rows' Markdown, which every row already pays once. One index publication relinks every cached row.
@main
struct TranscriptBench {
    enum Failure: Error { case validation(String) }

    struct Run: Encodable {
        let run: Int
        let renderMilliseconds: Double
        let linkMilliseconds: Double
        let unchangedMilliseconds: Double
        let links: Int
    }

    struct Report: Encodable {
        let workload: String
        let rows: Int
        let spansPerRow: Int
        let indexedPaths: Int
        let expectedLinks: Int
        let validationPassed: Bool
        let runs: [Run]
    }

    static let rows = 200
    static let indexed = 10_001

    static func main() throws {
        let paths = Set((0..<indexed).map { String(format: "src/group%03d/file%05d.swift", $0 % 100, $0) })
        let index = TranscriptPathIndex(paths: paths, roots: ["/w"], revision: 1)
        // Per row: 10 indexed paths (half absolute, half with a line), 5 missing paths and 5 non-path spans.
        let markdown = (0..<rows).map { row in
            var spans: [String] = []
            for item in 0..<10 {
                let number = (row * 10 + item) % indexed
                let path = String(format: "src/group%03d/file%05d.swift", number % 100, number)
                spans.append(item.isMultiple(of: 2) ? "`/w/\(path)`" : "`\(path):\(item + 1)`")
            }
            spans += (0..<5).map { "`missing/file\(row)-\($0).swift`" }
            spans += (0..<5).map { "`value\($0)()`" }
            return "Row \(row) touches " + spans.joined(separator: ", ") + "."
        }
        var runs: [Run] = []
        for run in 1...3 {
            var start = ContinuousClock.now
            let texts = markdown.map { MarkdownRenderer().render($0) }
            let render = start.duration(to: .now)

            start = .now
            var links = 0
            for text in texts {
                let linked = index.linkingInlineCode(in: text).text
                linked.enumerateAttribute(.link, in: NSRange(0..<linked.length)) { value, _, _ in
                    if value != nil { links += 1 }
                }
            }
            let link = start.duration(to: .now)

            // A publication that changes nothing still rescans each row's inline code.
            start = .now
            for text in texts { _ = index.linkingInlineCode(in: text) }
            let unchanged = start.duration(to: .now)

            runs.append(
                Run(
                    run: run,
                    renderMilliseconds: milliseconds(render),
                    linkMilliseconds: milliseconds(link),
                    unchangedMilliseconds: milliseconds(unchanged),
                    links: links
                )
            )
        }
        let expected = rows * 10
        let passed = runs.allSatisfy { $0.links == expected }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = Report(
            workload: "200 finished agent rows, 20 inline code spans each, against a 10,001-path index",
            rows: rows,
            spansPerRow: 20,
            indexedPaths: indexed,
            expectedLinks: expected,
            validationPassed: passed,
            runs: runs
        )
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
        guard passed else { throw Failure.validation("expected \(expected) links per run") }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
