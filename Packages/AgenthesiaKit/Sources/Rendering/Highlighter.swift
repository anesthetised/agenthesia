public import AppKit
import SwiftTreeSitter

/// Syntax highlighting for static code, such as code blocks in the transcript.
public struct Highlighter: Sendable {
    public var theme: Theme

    public init(theme: Theme = .standard) {
        self.theme = theme
    }

    /// The highlight captures of `code`: names like `keyword` with their ranges, less specific first.
    public func captures(in code: String, language: CodeLanguage) -> [(name: String, range: NSRange)] {
        guard let configuration = language.configuration, let query = configuration.queries[.highlights] else {
            return []
        }
        let parser = Parser()
        guard (try? parser.setLanguage(configuration.language)) != nil, let tree = parser.parse(code) else {
            return []
        }
        return query.execute(in: tree)
            .resolve(with: .init(string: code))
            .highlights()
            .map { ($0.name, $0.range) }
    }

    /// `code` in the code font, colored by `language`'s grammar. Unknown languages are not colored.
    public func highlight(_ code: String, language: CodeLanguage?) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(
            string: code,
            attributes: [.font: theme.codeFont, .foregroundColor: theme.textColor]
        )
        guard let language else { return result }
        let length = result.length
        for capture in captures(in: code, language: language) {
            guard let color = theme.color(forCapture: capture.name),
                capture.range.location != NSNotFound, NSMaxRange(capture.range) <= length
            else { continue }
            result.addAttribute(.foregroundColor, value: color, range: capture.range)
        }
        return result
    }
}
