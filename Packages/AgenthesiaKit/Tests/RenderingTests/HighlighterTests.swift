import AppKit
import Testing

@testable import Rendering

@Suite struct CodeLanguageTests {
    @Test func resolvesNamesAndAliases() {
        #expect(CodeLanguage(name: "swift") == .swift)
        #expect(CodeLanguage(name: "TS") == .typescript)
        #expect(CodeLanguage(name: "tsx") == .tsx)
        #expect(CodeLanguage(name: "jsx") == .javascript)
        #expect(CodeLanguage(name: "py") == .python)
        #expect(CodeLanguage(name: "zsh") == .bash)
        #expect(CodeLanguage(name: "console") == .bash)
        #expect(CodeLanguage(name: "rs") == .rust)
        #expect(CodeLanguage(name: "golang") == .go)
        #expect(CodeLanguage(name: "yml") == .yaml)
        #expect(CodeLanguage(name: "md") == .markdown)
        #expect(CodeLanguage(name: "jsonc") == .json)
        #expect(CodeLanguage(name: "swift title=\"Example\"") == .swift)
        #expect(CodeLanguage(name: "cobol") == nil)
        #expect(CodeLanguage(name: "") == nil)
    }

    @Test func resolvesPaths() {
        #expect(CodeLanguage(path: "/a/main.swift") == .swift)
        #expect(CodeLanguage(path: "/a/App.TSX") == .tsx)
        #expect(CodeLanguage(path: "/a/index.mjs") == .javascript)
        #expect(CodeLanguage(path: "/a/.zshrc") == .bash)
        #expect(CodeLanguage(path: "/a/Package.resolved") == .json)
        #expect(CodeLanguage(path: "/a/README") == nil)
        #expect(CodeLanguage(path: "/a/notes.txt") == nil)
    }

    @Test(arguments: CodeLanguage.allCases)
    func loadsEveryGrammar(language: CodeLanguage) {
        let configuration = language.configuration
        #expect(configuration != nil)
        #expect(configuration?.queries[.highlights] != nil)
        #expect(!language.displayName.isEmpty)
        // Cached on the second access.
        #expect(language.configuration?.name == configuration?.name)
    }

    @Test func missingBundlesAreNotFound() {
        #expect(CodeLanguage.queriesDirectory(inBundleNamed: "NoSuchGrammar_NoSuchGrammar") == nil)
    }
}

@Suite struct HighlighterTests {
    let highlighter = Highlighter()

    /// The capture names covering the first occurrence of `token` in `code`.
    private func captures(of token: String, in code: String, _ language: CodeLanguage) -> [String] {
        let range = (code as NSString).range(of: token)
        return highlighter.captures(in: code, language: language)
            .filter { NSIntersectionRange($0.range, range).length > 0 }
            .map(\.name)
    }

    static let samples: [(CodeLanguage, String, keyword: String, string: String, comment: String)] = [
        (.swift, "// note\nlet x = \"hi\"", "let", "\"hi\"", "// note"),
        (.typescript, "// note\nconst x: string = \"hi\";", "const", "\"hi\"", "// note"),
        (.tsx, "// note\nconst x = <div>{\"hi\"}</div>;", "const", "\"hi\"", "// note"),
        (.javascript, "// note\nconst x = \"hi\";", "const", "\"hi\"", "// note"),
        (.python, "# note\ndef f():\n    return \"hi\"", "def", "\"hi\"", "# note"),
        (.bash, "# note\nif true; then echo \"hi\"; fi", "if", "\"hi\"", "# note"),
        (.rust, "// note\nfn main() { let x = \"hi\"; }", "fn", "\"hi\"", "// note"),
        (.go, "// note\nfunc main() { x := \"hi\" }", "func", "\"hi\"", "// note"),
    ]

    @Test(arguments: samples.indices)
    func highlightsKeywordsStringsAndComments(index: Int) {
        let (language, code, keyword, string, comment) = Self.samples[index]
        #expect(captures(of: keyword, in: code, language).contains { $0.hasPrefix("keyword") }, "\(language)")
        #expect(captures(of: string, in: code, language).contains { $0.hasPrefix("string") }, "\(language)")
        #expect(captures(of: comment, in: code, language).contains { $0.hasPrefix("comment") }, "\(language)")
    }

    @Test func highlightsDataAndMarkupLanguages() {
        #expect(captures(of: "\"key\"", in: "{\"key\": 1}", .json).contains { $0.hasPrefix("string") })
        #expect(
            captures(of: "true", in: "enabled: true", .yaml).contains {
                $0.hasPrefix("boolean") || $0.hasPrefix("constant")
            }
        )
        #expect(
            captures(of: "Title", in: "# Title\n\nText", .markdown).contains {
                $0.contains("title") || $0.contains("heading")
            }
        )
    }

    @Test func appliesThemeColors() {
        let code = "let x = \"hi\""
        let result = highlighter.highlight(code, language: .swift)
        #expect(result.string == code)
        let keywordColor = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(keywordColor == Theme.standard.color(forCapture: "keyword"))
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }

    @Test func leavesUnknownLanguagesUncolored() {
        let result = highlighter.highlight("let x = 1", language: nil)
        var colors: Set<NSColor> = []
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color) }
        }
        #expect(colors == [Theme.standard.textColor])
        #expect(highlighter.captures(in: "", language: .swift).isEmpty)
    }
}

@Suite struct ThemeTests {
    @Test func resolvesCaptureColorsByPrefix() {
        let theme = Theme.standard
        #expect(theme.color(forCapture: "keyword.function") == theme.color(forCapture: "keyword"))
        #expect(theme.color(forCapture: "type.builtin") != theme.color(forCapture: "type"))
        #expect(theme.color(forCapture: "nothing.known") == nil)
        #expect(theme.color(forCapture: "") == nil)
    }

    @Test func colorsDifferBetweenLightAndDark() throws {
        let color = try #require(Theme.standard.color(forCapture: "keyword"))
        func resolved(_ name: NSAppearance.Name) -> NSColor? {
            var result: NSColor?
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB)
            }
            return result
        }
        #expect(resolved(.aqua) != resolved(.darkAqua))
        #expect(resolved(.aqua) == NSColor(rgb: 0x9B2393).usingColorSpace(.sRGB))
    }

    @Test func fonts() {
        let theme = Theme(fontSize: 14)
        #expect(theme.bodyFont.pointSize == 14)
        #expect(theme.codeFont.pointSize == 13)
        #expect(theme.codeFont.isFixedPitch)
        #expect(theme.headingFont(level: 1).pointSize > theme.headingFont(level: 2).pointSize)
        #expect(theme.headingFont(level: 3).pointSize > theme.headingFont(level: 4).pointSize)
        #expect(theme.headingFont(level: 6).pointSize == 14)
        for color in [
            theme.textColor, theme.secondaryTextColor, theme.linkColor, theme.codeBackgroundColor, theme.quoteBarColor,
        ] {
            #expect(color.type == .catalog || color.type == .componentBased)
        }
    }
}
