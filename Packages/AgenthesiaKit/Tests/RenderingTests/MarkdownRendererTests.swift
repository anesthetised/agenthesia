import AppKit
import Testing

@testable import Rendering

@Suite struct MarkdownRendererTests {
    let theme = Theme.standard
    let renderer = MarkdownRenderer()

    private func render(_ markdown: String) -> NSAttributedString {
        renderer.render(markdown)
    }

    /// The attributes at the first occurrence of `token`.
    private func attrs(
        of token: String,
        in text: NSAttributedString
    ) throws -> [NSAttributedString.Key: Any] {
        let range = (text.string as NSString).range(of: token)
        try #require(range.location != NSNotFound, "\(token) not found in \(text.string)")
        return text.attributes(at: range.location, effectiveRange: nil)
    }

    private func traits(of token: String, in text: NSAttributedString) throws -> NSFontDescriptor.SymbolicTraits {
        let font = try #require(try attrs(of: token, in: text)[.font] as? NSFont)
        return font.fontDescriptor.symbolicTraits
    }

    private func style(of token: String, in text: NSAttributedString) throws -> NSParagraphStyle {
        try #require(try attrs(of: token, in: text)[.paragraphStyle] as? NSParagraphStyle)
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func closingFenceRespectsBlockStructure(newline: String) {
        func closing(_ lines: [String]) -> String? {
            MarkdownRenderer.closingCodeFence(in: lines.joined(separator: newline))
        }
        #expect(closing(["Text", "", "  ````swift", "let value = 1"]) == "````")
        #expect(closing(["~~~", "```", "~~~ trailing"]) == "~~~")
        #expect(closing(["```", "code", "```` \t"]) == nil)
        #expect(closing(["- ```", "  code", "  ```"]) == nil)
        #expect(closing(["> ~~~", "> code"]) == nil)
        #expect(closing(["    ```", "    code"]) == nil)
        #expect(closing(["``` invalid ` info", "text"]) == nil)
        #expect(MarkdownRenderer.closingCodeFence(in: "") == nil)
    }

    // MARK: Blocks

    @Test func emptyInputRendersNothing() {
        #expect(render("").length == 0)
        #expect(render("\n\n").length == 0)
    }

    @Test func paragraphUsesBodyStyle() throws {
        let text = render("Hello world")
        #expect(text.string == "Hello world")
        let attributes = try attrs(of: "Hello", in: text)
        #expect(attributes[.font] as? NSFont == theme.bodyFont)
        #expect(attributes[.foregroundColor] as? NSColor == theme.textColor)
        #expect(try style(of: "Hello", in: text).paragraphSpacing == theme.blockSpacing)
    }

    @Test func blocksAreSeparatedByOneNewline() {
        #expect(render("one\n\ntwo\n\n# three").string == "one\ntwo\nthree")
    }

    @Test func headingsScaleByLevel() throws {
        let text = render("# One\n\n## Two\n\n### Three\n\n#### Four")
        for (token, level) in [("One", 1), ("Two", 2), ("Three", 3), ("Four", 4)] {
            let font = try #require(try attrs(of: token, in: text)[.font] as? NSFont)
            #expect(font == theme.headingFont(level: level))
        }
        #expect(try traits(of: "One", in: text).contains(.bold))
        #expect(
            try #require(try attrs(of: "One", in: text)[.font] as? NSFont).pointSize
                > theme.bodyFont.pointSize
        )
    }

    @Test func smartPunctuationIsLeftAlone() {
        #expect(render("a -- b \"c\" ... d").string == "a -- b \"c\" ... d")
    }

    @Test func thematicBreakIsARule() throws {
        let text = render("above\n\n---\n\nbelow")
        #expect(text.string.contains("────"))
        #expect(try attrs(of: "───", in: text)[.foregroundColor] as? NSColor == theme.quoteBarColor)
    }

    @Test func blockQuoteIsIndentedAndMuted() throws {
        let text = render("> quoted\n>\n> > nested\n\nafter")
        #expect(text.string == "quoted\nnested\nafter")
        let quoted = try style(of: "quoted", in: text)
        #expect(quoted.headIndent == theme.indent)
        #expect(quoted.firstLineHeadIndent == theme.indent)
        #expect(try attrs(of: "quoted", in: text)[.foregroundColor] as? NSColor == theme.secondaryTextColor)
        #expect(try style(of: "nested", in: text).headIndent == theme.indent * 2)
        #expect(try style(of: "nested", in: text).paragraphSpacing == theme.blockSpacing)
        #expect(try style(of: "after", in: text).headIndent == 0)
    }

    @Test func htmlIsShownAsCode() throws {
        let text = render("<div>raw</div>\n\ntext <b>inline</b>")
        #expect(text.string == "<div>raw</div>\ntext <b>inline</b>")
        #expect(try attrs(of: "<div>", in: text)[.font] as? NSFont == theme.codeFont)
        #expect(try attrs(of: "<b>", in: text)[.foregroundColor] as? NSColor == theme.secondaryTextColor)
    }

    // MARK: Inlines

    @Test func emphasisStrongAndStrikethrough() throws {
        let text = render("*em* **strong** ~~gone~~ ***both*** plain")
        #expect(text.string == "em strong gone both plain")
        #expect(try traits(of: "em", in: text) == [.italic])
        #expect(try traits(of: "strong", in: text) == [.bold])
        #expect(try traits(of: "both", in: text) == [.bold, .italic])
        #expect(try traits(of: "plain", in: text).isDisjoint(with: [.bold, .italic]))
        #expect(
            try attrs(of: "gone", in: text)[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue
        )
        #expect(try attrs(of: "plain", in: text)[.strikethroughStyle] == nil)
    }

    @Test func inlineCodeUsesCodeFontAndBackground() throws {
        let text = render("call `foo()` now")
        #expect(text.string == "call foo() now")
        let attributes = try attrs(of: "foo", in: text)
        #expect(attributes[.font] as? NSFont == theme.codeFont)
        #expect(attributes[.backgroundColor] as? NSColor == theme.codeBackgroundColor)
        #expect(try attrs(of: "now", in: text)[.backgroundColor] == nil)
    }

    @Test func linksCarryTheirDestination() throws {
        let text = render("see [the **docs**](https://example.com/a) and [nowhere]()")
        let docs = try attrs(of: "docs", in: text)
        #expect(docs[.link] as? URL == URL(string: "https://example.com/a"))
        #expect(docs[.foregroundColor] as? NSColor == theme.linkColor)
        #expect(try traits(of: "docs", in: text).contains(.bold))
        #expect(try attrs(of: "see", in: text)[.link] == nil)
        #expect(try attrs(of: "nowhere", in: text)[.link] == nil)
    }

    @Test func imagesShowTheirAltTextAsALink() throws {
        let text = render("![a cat](https://example.com/cat.png) ![](https://example.com/dog.png)")
        #expect(text.string == "a cat https://example.com/dog.png")
        #expect(try attrs(of: "a cat", in: text)[.link] as? URL == URL(string: "https://example.com/cat.png"))
    }

    @Test func breaks() {
        #expect(render("one\ntwo").string == "one two")
        #expect(render("one\\\ntwo").string == "one\u{2028}two")
    }

    // MARK: Code blocks

    @Test func codeBlockIsHighlighted() throws {
        let text = render("before\n\n```swift\nlet x = 1\n```\n\nafter")
        #expect(text.string == "before\nlet x = 1\nafter")
        let keyword = try attrs(of: "let", in: text)
        #expect(keyword[.foregroundColor] as? NSColor == theme.color(forCapture: "keyword"))
        #expect(keyword[.font] as? NSFont == theme.codeFont)
        #expect(keyword[.backgroundColor] as? NSColor == theme.codeBackgroundColor)
        #expect(try attrs(of: "after", in: text)[.backgroundColor] == nil)
    }

    @Test func codeBlockWithoutKnownLanguageIsPlain() throws {
        for fence in ["```", "```cobol"] {
            let text = render("\(fence)\nlet x = 1\n```")
            let attributes = try attrs(of: "let", in: text)
            #expect(attributes[.foregroundColor] as? NSColor == theme.textColor)
            #expect(attributes[.font] as? NSFont == theme.codeFont)
        }
    }

    @Test func codeBlockSpacesOnlyAfterTheLastLine() throws {
        let text = render("```\none\ntwo\nthree\n```\n\nafter")
        #expect(text.string == "one\ntwo\nthree\nafter")
        #expect(try style(of: "one", in: text).paragraphSpacing == 0)
        #expect(try style(of: "two", in: text).paragraphSpacing == 0)
        #expect(try style(of: "three", in: text).paragraphSpacing == theme.blockSpacing)
    }

    @Test func emptyAndUnclosedCodeBlocks() {
        #expect(render("```\n```").length == 0)
        #expect(render("```swift\nlet x = 1").string == "let x = 1")
    }

    // MARK: Lists

    @Test func bulletList() throws {
        let text = render("- one\n- two\n\nafter")
        #expect(text.string == "•\tone\n•\ttwo\nafter")
        let item = try style(of: "one", in: text)
        #expect(item.firstLineHeadIndent == 0)
        #expect(item.headIndent == theme.indent)
        #expect(item.tabStops.first?.location == theme.indent)
        #expect(item.paragraphSpacing == theme.itemSpacing)
        // The list as a whole is spaced like a block.
        #expect(try style(of: "two", in: text).paragraphSpacing == theme.blockSpacing)
    }

    @Test func orderedListKeepsItsStartNumber() throws {
        let text = render("3. three\n4. four")
        #expect(text.string == "3.\tthree\n4.\tfour")
    }

    @Test func wideOrderedMarkersGetMoreRoom() throws {
        let items = (1...100).map { "\($0). item\($0)" }.joined(separator: "\n")
        let text = render(items)
        #expect(try style(of: "item1", in: text).headIndent > theme.indent)
    }

    @Test func taskList() {
        #expect(render("- [x] done\n- [ ] todo\n- plain").string == "☑\tdone\n☐\ttodo\n•\tplain")
    }

    @Test func nestedListsIndentFurther() throws {
        let text = render("- outer\n  - inner\n    - deepest")
        #expect(text.string == "•\touter\n•\tinner\n•\tdeepest")
        #expect(try style(of: "outer", in: text).firstLineHeadIndent == 0)
        #expect(try style(of: "inner", in: text).firstLineHeadIndent == theme.indent)
        #expect(try style(of: "deepest", in: text).firstLineHeadIndent == theme.indent * 2)
        #expect(try style(of: "deepest", in: text).headIndent == theme.indent * 3)
    }

    @Test func listItemsCanHoldSeveralBlocks() throws {
        let text = render("1. intro\n\n   more text\n\n   ```swift\n   let x = 1\n   ```\n2. next")
        #expect(text.string == "1.\tintro\nmore text\nlet x = 1\n2.\tnext")
        #expect(try style(of: "more", in: text).firstLineHeadIndent == theme.indent)
        #expect(try style(of: "more", in: text).headIndent == theme.indent)
        #expect(try attrs(of: "let", in: text)[.foregroundColor] as? NSColor == theme.color(forCapture: "keyword"))
    }

    @Test func listItemsThatDoNotStartWithAParagraph() throws {
        let text = render("- ```\n  code\n  ```\n-\n- - nested")
        #expect(text.string == "•\ncode\n•\n•\n•\tnested")
        #expect(try attrs(of: "code", in: text)[.font] as? NSFont == theme.codeFont)
    }

    // MARK: Tables

    @Test func tableIsAlignedMonospacedText() throws {
        let text = render(
            """
            | Name | Qty | Note |
            |:-----|----:|:----:|
            | apple | 3 | ok |
            | **kiwi** | 12 | fine |
            """
        )
        #expect(
            text.string
                == """
                Name  │ Qty │ Note
                ──────┼─────┼─────
                apple │   3 │  ok\u{20}
                kiwi  │  12 │ fine
                """
        )
        #expect(try traits(of: "Name", in: text).contains([.bold, .monoSpace]))
        #expect(try traits(of: "kiwi", in: text).contains(.bold))
        #expect(try traits(of: "apple", in: text).isDisjoint(with: .bold))
        #expect(try style(of: "apple", in: text).paragraphSpacing == 0)
        #expect(try style(of: "kiwi", in: text).paragraphSpacing == theme.blockSpacing)
    }
}
