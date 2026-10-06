import AppKit
import Testing

@testable import Rendering

@Suite struct StreamingMarkdownTests {
    let renderer = MarkdownRenderer()

    /// Covers every block kind, an unclosed-then-closed code block, and text that restyles as it grows.
    static let document = """
        # Title

        Some *emphasis*, **strong text** and `code`, with a [link](https://example.com) and ~~gone~~.
        A second line, then a hard break\\
        and more.

        > A quote
        > over two lines

        - first
        - [x] done
          - nested item
        - [ ] todo

        3. three
        4. four

        ```swift
        let greeting = "héllo 👩‍💻"
        print(greeting)
        ```

        | a | b |
        |---|--:|
        | 1 | 22 |

        ---

        <div>html</div>

        ```python
        def f():
            return 1
        ```

        The end, with an unclosed block:

        ```
        tail
        """

    /// The chunks of `text` of random length, cut at unicode scalars (so also inside characters and markers).
    private func chunks(of text: String, seed: UInt64, maxLength: Int = 12) -> [String] {
        var generator = SplitMix64(seed: seed)
        let scalars = Array(text.unicodeScalars)
        var chunks: [String] = []
        var index = 0
        while index < scalars.count {
            let end = min(index + Int.random(in: 1...maxLength, using: &generator), scalars.count)
            var chunk = String.UnicodeScalarView()
            chunk.append(contentsOf: scalars[index..<end])
            chunks.append(String(chunk))
            index = end
        }
        return chunks
    }

    @Test(arguments: [1, 2, 3, 42, 1234, 99_999])
    func anyChunkingRendersLikeOneShot(seed: UInt64) {
        var streaming = StreamingMarkdown(renderer: renderer)
        let view = NSMutableAttributedString()
        var received = ""
        for chunk in chunks(of: Self.document, seed: seed) {
            received += chunk
            let previous = view.copy() as? NSAttributedString ?? NSAttributedString()
            let update = streaming.append(chunk)

            // The stable prefix is really what the view already had.
            #expect(update.stablePrefixLength <= previous.length)
            #expect(
                previous.attributedSubstring(from: NSRange(0..<update.stablePrefixLength))
                    .isEqual(
                        to: streaming.attributedString.attributedSubstring(from: NSRange(0..<update.stablePrefixLength))
                    )
            )
            update.apply(to: view)

            #expect(streaming.source == received)
            #expect(view.isEqual(to: renderer.render(received)), "after \(received.debugDescription)")
        }
        #expect(streaming.source == Self.document)
        #expect(view.isEqual(to: renderer.render(Self.document)))
        #expect(streaming.attributedString.isEqual(to: renderer.render(Self.document)))
    }

    @Test(arguments: [1, 2, 3, 42])
    func stablePrefixOnlyMovesForward(seed: UInt64) {
        var streaming = StreamingMarkdown(renderer: renderer)
        var previous = 0
        for chunk in chunks(of: Self.document, seed: seed, maxLength: 40) {
            let update = streaming.append(chunk)
            #expect(update.stablePrefixLength >= previous, "after \(streaming.source.debugDescription)")
            previous = update.stablePrefixLength
        }
    }

    @Test func onlyTheLastBlockIsReplaced() {
        var streaming = StreamingMarkdown(renderer: renderer)
        _ = streaming.append("# Title\n\npar")
        let update = streaming.append("a")
        #expect(update.stablePrefixLength == "Title".count)
        #expect(update.tail.string == "\npara")

        let next = streaming.append("\n\nnew block")
        // The paragraph is final now, and the new block starts the tail.
        #expect(next.stablePrefixLength == "Title\npara".count)
        #expect(next.tail.string == "\nnew block")
    }

    @Test func unclosedCodeBlockStreamsAndThenCloses() throws {
        var streaming = StreamingMarkdown(renderer: renderer)
        let view = NSMutableAttributedString()
        streaming.append("Intro\n\n```swift\nlet x").apply(to: view)
        #expect(view.string == "Intro\nlet x")
        let keyword = view.attributes(at: "Intro\n".count, effectiveRange: nil)
        #expect(keyword[.foregroundColor] as? NSColor == Theme.standard.color(forCapture: "keyword"))

        let update = streaming.append(" = 1\n```\n\nDone")
        #expect(update.stablePrefixLength == "Intro".count)
        update.apply(to: view)
        #expect(view.string == "Intro\nlet x = 1\nDone")
        #expect(view.isEqual(to: renderer.render("Intro\n\n```swift\nlet x = 1\n```\n\nDone")))
    }

    @Test func aLateDefinitionRestylesEarlierBlocks() throws {
        var streaming = StreamingMarkdown(renderer: renderer)
        let view = NSMutableAttributedString()
        streaming.append("[docs]\n\nmiddle\n\n").apply(to: view)
        #expect(view.attribute(.link, at: 1, effectiveRange: nil) == nil)

        let update = streaming.append("[docs]: https://example.com")
        // The first block is a link now, so nothing before it can be kept.
        #expect(update.stablePrefixLength == 0)
        update.apply(to: view)
        #expect(view.attribute(.link, at: 1, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
        #expect(view.isEqual(to: renderer.render("[docs]\n\nmiddle\n\n[docs]: https://example.com")))
    }

    @Test func removedBlocksAreTruncated() {
        var streaming = StreamingMarkdown(renderer: renderer)
        let view = NSMutableAttributedString()
        // A setext underline turns the paragraph and the rule into one heading.
        streaming.append("title\n\n---").apply(to: view)
        #expect(view.string.contains("────"))
        streaming = StreamingMarkdown(renderer: renderer)
        view.setAttributedString(NSAttributedString())
        streaming.append("title\n---").apply(to: view)
        #expect(view.string == "title")
    }

    @Test func emptyChunksChangeNothing() {
        var streaming = StreamingMarkdown(renderer: renderer)
        let first = streaming.append("one\n\ntwo")
        let again = streaming.append("")
        #expect(again.stablePrefixLength == first.stablePrefixLength + first.tail.length)
        #expect(again.tail.length == 0)
        #expect(streaming.attributedString.string == "one\ntwo")
    }

    @Test func startsEmpty() {
        let streaming = StreamingMarkdown()
        #expect(streaming.source.isEmpty)
        #expect(streaming.attributedString.length == 0)
    }
}

/// A small deterministic random number generator for reproducible tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
