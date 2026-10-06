public import AppKit
import Markdown

/// Renders Markdown that arrives in chunks, re-rendering only what a chunk changed.
///
/// Each chunk re-parses the text (cmark is linear and fast) but renders only the blocks that differ from the
/// previous parse: in practice the last one, including an unclosed code block. Blocks that did not change keep
/// their rendered text, so a text view replaces just the tail.
public struct StreamingMarkdown {
    /// What a text view has to do after a chunk.
    public struct Update {
        /// The length of the text before the change; it is the same as in the view already. It only grows while
        /// the text streams in, except when a late definition (`[link]: url`) restyles an earlier block.
        public let stablePrefixLength: Int
        /// What replaces everything after the stable prefix.
        public let tail: NSAttributedString

        /// Applies the update to `text`, which holds the previous result.
        public func apply(to text: NSMutableAttributedString) {
            text.replaceCharacters(
                in: NSRange(location: stablePrefixLength, length: text.length - stablePrefixLength),
                with: tail
            )
        }
    }

    private struct Block {
        let markup: any BlockMarkup
        /// The block's text, with the separator that precedes it unless it is the first.
        let text: NSAttributedString
    }

    private let renderer: MarkdownRenderer
    private var blocks: [Block] = []

    /// All the Markdown received so far.
    public private(set) var source = ""

    public init(renderer: MarkdownRenderer = MarkdownRenderer()) {
        self.renderer = renderer
    }

    /// The rendering of everything received so far; equal to `MarkdownRenderer.render(source)`.
    public var attributedString: NSAttributedString {
        let result = NSMutableAttributedString()
        for block in blocks { result.append(block.text) }
        return result
    }

    /// Adds `chunk` to the text.
    public mutating func append(_ chunk: String) -> Update {
        source += chunk
        let markups = renderer.blocks(in: source)

        var updated: [Block] = []
        var stableLength = 0
        var stableCount = 0
        for (index, markup) in markups.enumerated() {
            if index < blocks.count, blocks[index].markup.hasSameStructure(as: markup) {
                updated.append(blocks[index])
                if stableCount == index {
                    stableCount += 1
                    stableLength += blocks[index].text.length
                }
            } else {
                let text = NSMutableAttributedString()
                if index > 0 { text.append(renderer.separator) }
                text.append(renderer.render(block: markup))
                updated.append(Block(markup: markup, text: text))
            }
        }
        blocks = updated

        let tail = NSMutableAttributedString()
        for block in updated[stableCount...] { tail.append(block.text) }
        return Update(stablePrefixLength: stableLength, tail: tail)
    }
}
