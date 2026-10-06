public import AppKit
import Markdown

/// Renders Markdown to an attributed string for display in a text view.
///
/// Every block renders on its own, without looking at its neighbors; blocks are joined by a newline. That is what
/// lets ``StreamingMarkdown`` re-render only the block that changed.
public struct MarkdownRenderer: Sendable {
    public var theme: Theme

    public init(theme: Theme = .standard) {
        self.theme = theme
    }

    /// `markdown` as styled text: no trailing newline, paragraph spacing in paragraph styles.
    public func render(_ markdown: String) -> NSAttributedString {
        join(blocks(in: markdown).map { render(block: $0) })
    }

    // MARK: - Blocks

    /// The top-level blocks of `markdown`. Smart punctuation is off: agents write code and dashes that must stay.
    func blocks(in markdown: String) -> [any BlockMarkup] {
        Array(Document(parsing: markdown, options: [.disableSmartOpts]).blockChildren)
    }

    /// A top-level block, with no separator.
    func render(block: any BlockMarkup) -> NSAttributedString {
        render(block, Context(theme: theme))
    }

    /// The newline between two blocks.
    var separator: NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.font: theme.bodyFont])
    }

    func join(_ parts: [NSAttributedString]) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { result.append(separator) }
            result.append(part)
        }
        return result
    }

    private func render(_ block: any BlockMarkup, _ context: Context) -> NSMutableAttributedString {
        switch block {
        case let heading as Heading:
            var context = context
            context.font = theme.headingFont(level: heading.level)
            return paragraph(inlines(of: heading, context), context)
        case let paragraph as Paragraph:
            return self.paragraph(inlines(of: paragraph, context), context)
        case let code as CodeBlock:
            return codeBlock(code, context)
        case let quote as BlockQuote:
            var context = context
            context.indent += theme.indent
            context.color = theme.secondaryTextColor
            let result = join(quote.blockChildren.map { render($0, context) })
            applySpacing(theme.blockSpacing, toLastParagraphOf: result)
            return result
        case is ThematicBreak:
            var context = context
            context.color = theme.quoteBarColor
            return paragraph(styled(String(repeating: "─", count: 24), context), context)
        case let list as UnorderedList:
            let items = Array(list.listItems)
            return self.list(items, markers: items.map { bullet(for: $0) }, markerWidth: theme.indent, context)
        case let list as OrderedList:
            let items = Array(list.listItems)
            let first = Int(list.startIndex)
            let markers = items.indices.map { "\(first + $0)." }
            let digits = String(first + max(items.count - 1, 0)).count
            let width = theme.indent + CGFloat(max(digits - 2, 0)) * theme.fontSize * 0.6
            return self.list(items, markers: markers, markerWidth: width, context)
        case let table as Table:
            return self.table(table, context)
        case let html as HTMLBlock:
            var context = context
            context.font = theme.codeFont
            context.color = theme.secondaryTextColor
            return paragraph(styled(withoutTrailingNewline(html.rawHTML), context), context)
        default:
            return paragraph(styled(block.format(), context), context)
        }
    }

    private func paragraph(_ text: NSMutableAttributedString, _ context: Context) -> NSMutableAttributedString {
        setStyle(on: text, indent: context.indent, spacing: context.spacing)
        return text
    }

    private func codeBlock(_ block: CodeBlock, _ context: Context) -> NSMutableAttributedString {
        let language = block.language.flatMap { CodeLanguage(name: $0) }
        let text = Highlighter(theme: theme).highlight(withoutTrailingNewline(block.code), language: language)
        text.addAttribute(.backgroundColor, value: theme.codeBackgroundColor, range: NSRange(0..<text.length))
        return paragraph(text, context)
    }

    // MARK: Lists

    private func bullet(for item: ListItem) -> String {
        switch item.checkbox {
        case .checked: "☑"
        case .unchecked: "☐"
        case nil: "•"
        }
    }

    /// A list whose item content is indented by `markerWidth`. Item content is spaced by `itemSpacing`; the list
    /// as a whole by the surrounding spacing.
    private func list(
        _ items: [ListItem],
        markers: [String],
        markerWidth: CGFloat,
        _ context: Context
    ) -> NSMutableAttributedString {
        var content = context
        content.indent = context.indent + markerWidth
        content.spacing = theme.itemSpacing
        var parts: [NSAttributedString] = []
        for (item, marker) in zip(items, markers) {
            var children = Array(item.blockChildren)
            let line: NSMutableAttributedString
            if let first = children.first as? Paragraph {
                line = styled("\(marker)\t", content)
                line.append(inlines(of: first, content))
                children.removeFirst()
            } else {
                line = styled(marker, content)
            }
            setStyle(
                on: line,
                indent: content.indent,
                firstLine: context.indent,
                tabStop: content.indent,
                spacing: content.spacing
            )
            parts.append(line)
            parts += children.map { render($0, content) }
        }
        let result = join(parts)
        applySpacing(context.spacing, toLastParagraphOf: result)
        return result
    }

    // MARK: Tables

    /// A table as aligned monospaced text: the spike's stand-in for a real grid.
    private func table(_ table: Table, _ context: Context) -> NSMutableAttributedString {
        var cellContext = context
        cellContext.font = theme.codeFont
        var headerContext = cellContext
        headerContext.font = withTraits(.bold, theme.codeFont)

        var rows: [[NSMutableAttributedString]] = [Array(table.head.cells.map { inlines(of: $0, headerContext) })]
        rows += table.body.rows.map { row in Array(row.cells.map { inlines(of: $0, cellContext) }) }
        let columnCount = rows.map(\.count).max() ?? 0
        let widths = (0..<columnCount).map { column in
            rows.map { column < $0.count ? $0[column].string.count : 0 }.max() ?? 0
        }
        let alignments = table.columnAlignments

        var ruleContext = cellContext
        ruleContext.color = theme.quoteBarColor
        let divider = styled(" │ ", ruleContext)
        let result = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 { result.append(styled("\n", cellContext)) }
            for column in 0..<columnCount {
                if column > 0 { result.append(divider) }
                let cell = column < row.count ? row[column] : NSMutableAttributedString()
                let padding = widths[column] - cell.string.count
                let alignment = column < alignments.count ? alignments[column] : nil
                let (before, after) =
                    switch alignment {
                    case .right: (padding, 0)
                    case .center: (padding / 2, padding - padding / 2)
                    default: (0, padding)
                    }
                result.append(styled(String(repeating: " ", count: before), cellContext))
                result.append(cell)
                result.append(styled(String(repeating: " ", count: after), cellContext))
            }
            if rowIndex == 0 {
                let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "─┼─")
                result.append(styled("\n" + rule, ruleContext))
            }
        }
        return paragraph(result, context)
    }

    // MARK: - Inlines

    private func inlines(of container: any Markup, _ context: Context) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for child in container.children { append(child, context, to: result) }
        return result
    }

    private func append(_ markup: any Markup, _ context: Context, to result: NSMutableAttributedString) {
        switch markup {
        case let text as Markdown.Text:
            result.append(styled(text.string, context))
        case is SoftBreak:
            result.append(styled(" ", context))
        case is LineBreak:
            // A line separator breaks the line without starting a new paragraph.
            result.append(styled("\u{2028}", context))
        case let emphasis as Emphasis:
            var context = context
            context.font = withTraits(.italic, context.font)
            result.append(inlines(of: emphasis, context))
        case let strong as Strong:
            var context = context
            context.font = withTraits(.bold, context.font)
            result.append(inlines(of: strong, context))
        case let strikethrough as Strikethrough:
            var context = context
            context.strikethrough = true
            result.append(inlines(of: strikethrough, context))
        case let code as InlineCode:
            result.append(inlineCode(code.code, context))
        case let link as Markdown.Link:
            var context = context
            context.link = link.destination.flatMap { URL(string: $0) }
            result.append(inlines(of: link, context))
        case let image as Markdown.Image:
            var context = context
            context.link = image.source.flatMap { URL(string: $0) }
            let alt = image.plainText
            result.append(styled(alt.isEmpty ? (image.source ?? "") : alt, context))
        case let html as InlineHTML:
            var context = context
            context.color = theme.secondaryTextColor
            result.append(styled(html.rawHTML, context))
        default:
            result.append(styled((markup as? any InlineMarkup)?.plainText ?? markup.format(), context))
        }
    }

    private func inlineCode(_ code: String, _ context: Context) -> NSMutableAttributedString {
        var context = context
        context.font = theme.codeFont
        let text = styled(code, context)
        text.addAttribute(.backgroundColor, value: theme.codeBackgroundColor, range: NSRange(0..<text.length))
        return text
    }

    // MARK: - Attributes

    /// The inline state while walking the tree: what applies to the text being appended.
    private struct Context {
        var font: NSFont
        var color: NSColor
        var indent: CGFloat = 0
        var spacing: CGFloat
        var strikethrough = false
        var link: URL?

        init(theme: Theme) {
            font = theme.bodyFont
            color = theme.textColor
            spacing = theme.blockSpacing
        }
    }

    private func styled(_ string: String, _ context: Context) -> NSMutableAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: context.font, .foregroundColor: context.color]
        if context.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = context.link {
            attributes[.link] = link
            attributes[.foregroundColor] = theme.linkColor
        }
        return NSMutableAttributedString(string: string, attributes: attributes)
    }

    private func withTraits(_ traits: NSFontDescriptor.SymbolicTraits, _ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Indents `text` and spaces it from the next paragraph. A block with several lines (code, tables) gets the
    /// spacing only after its last one.
    private func setStyle(
        on text: NSMutableAttributedString,
        indent: CGFloat,
        firstLine: CGFloat? = nil,
        tabStop: CGFloat? = nil,
        spacing: CGFloat
    ) {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = firstLine ?? indent
        style.paragraphSpacing = text.string.contains("\n") ? 0 : spacing
        if let tabStop {
            style.tabStops = [NSTextTab(textAlignment: .left, location: tabStop)]
        }
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(0..<text.length))
        if text.string.contains("\n") {
            applySpacing(spacing, toLastParagraphOf: text)
        }
    }

    private func applySpacing(_ spacing: CGFloat, toLastParagraphOf text: NSMutableAttributedString) {
        guard text.length > 0 else { return }
        let last = (text.string as NSString).paragraphRange(for: NSRange(location: text.length - 1, length: 0))
        let existing = text.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        text.addAttribute(.paragraphStyle, value: style, range: last)
    }

    /// cmark ends code and HTML blocks with a newline that is not part of the content.
    private func withoutTrailingNewline(_ string: String) -> String {
        string.hasSuffix("\n") ? String(string.dropLast()) : string
    }
}
