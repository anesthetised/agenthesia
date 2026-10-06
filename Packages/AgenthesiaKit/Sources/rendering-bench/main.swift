import AppKit
import Rendering

// Timings of the rendering pieces that do not need a window, printed as Markdown tables for ADR-0007.
// Build in release: `just bench`.

/// Runs `body` `iterations` times and returns the median time in milliseconds.
func median(_ iterations: Int, _ body: () -> Void) -> Double {
    var times: [Double] = []
    for _ in 0..<iterations {
        times.append(milliseconds { body() })
    }
    return times.sorted()[times.count / 2]
}

func milliseconds(_ body: () -> Void) -> Double {
    let elapsed = ContinuousClock().measure(body)
    return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
}

func format(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1)))
}

/// Free memory in percent, as `memory_pressure` reports it, and the load average over the last minute.
func systemLoad() -> String {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0)
    var load = 0.0
    getloadavg(&load, 1)
    let cores = ProcessInfo.processInfo.activeProcessorCount
    return "free RAM \(level)%, load \(format(load)) on \(cores) cores"
}

// MARK: - Fixtures

/// A Markdown answer of about `characters` characters: headings, paragraphs, lists, quotes and code.
func answer(characters: Int) -> String {
    let blocks = [
        "## Rendering the transcript",
        "The agent reads the file, then writes a change because the session needs a new `render()` step. "
            + "Each **block** is cached once it is complete, and only the tail is laid out again.",
        "- Parse the text with cmark\n- Render each block to an attributed string\n- [x] Highlight code blocks",
        "```swift\nfunc render(_ text: String) -> NSAttributedString {\n    let document = Document(parsing: text)\n"
            + "    return renderer.render(document) // cached\n}\n```",
        "> Streaming chunks arrive every few milliseconds, so rendering must stay well under a frame.",
        "1. Open the session\n2. Scroll to the end\n3. Follow the stream",
        "```python\ndef frames(times: list[float]) -> float:\n    return sorted(times)[int(len(times) * 0.95)]\n```",
    ]
    var parts: [String] = []
    var length = 0
    while length < characters {
        let block = blocks[parts.count % blocks.count]
        parts.append(block)
        length += block.count + 2
    }
    return parts.joined(separator: "\n\n")
}

/// A file of `lines` lines in `language`.
func sourceFile(_ language: CodeLanguage, lines: Int) -> String {
    if language == .json {
        let items = (0..<(lines - 2) / 6).map { index in
            "  {\n    \"id\": \(index),\n    \"name\": \"item-\(index)\",\n    \"enabled\": true,\n    \"ratio\": 0.5\n  }"
        }
        return "[\n" + items.joined(separator: ",\n") + "\n]"
    }
    let block = snippets[language] ?? ""
    var result: [Substring] = []
    while result.count < lines {
        result += block.split(separator: "\n", omittingEmptySubsequences: false)
    }
    return result.prefix(lines).joined(separator: "\n")
}

let snippets: [CodeLanguage: String] = [
    .swift: """
    /// Handles a request.
    struct Handler: Sendable {
        let name = "handler"
        func process(_ input: [String]) -> Int { input.filter { $0.hasPrefix(name) }.count + 42 }
    }

    """,
    .typescript: """
    // Loads a session.
    export async function load(id: string): Promise<Session> {
      const response = await fetch(`/sessions/${id}`);
      return (await response.json()) as Session;
    }

    """,
    .tsx: """
    // Shows a session.
    export function SessionView({ session }: { session: Session }) {
      const [open, setOpen] = useState(false);
      return <div className="session" onClick={() => setOpen(!open)}>{session.title}</div>;
    }

    """,
    .javascript: """
    // Counts the frames.
    export function count(frames, limit = 16.7) {
      const slow = frames.filter((frame) => frame > limit);
      return { total: frames.length, slow: slow.length, ratio: slow.length / frames.length };
    }

    """,
    .python: """
    # The 95th percentile of frame times.
    def p95(times: list[float]) -> float:
        ordered = sorted(times)
        return ordered[int(len(ordered) * 0.95)] if ordered else 0.0

    """,
    .markdown: """
    ## Section

    Some *emphasis*, **strong** text and `code`, with a [link](https://example.com).

    - first item
    - second item

    """,
    .bash: """
    # Builds and runs the benchmarks.
    if [ -n "$CI" ]; then
      echo "skipping on $CI" && exit 0
    fi
    swift build -c release --product rendering-bench && ./.build/release/rendering-bench

    """,
    .rust: """
    /// The 95th percentile of frame times.
    pub fn p95(times: &mut Vec<f64>) -> f64 {
        times.sort_by(|a, b| a.partial_cmp(b).unwrap());
        times.get(times.len() * 95 / 100).copied().unwrap_or(0.0)
    }

    """,
    .go: """
    // P95 returns the 95th percentile of frame times.
    func P95(times []float64) float64 {
    \tsort.Float64s(times)
    \treturn times[len(times)*95/100]
    }

    """,
    .yaml: """
    # A CI job.
    build:
      runs-on: macos-26
      steps:
        - uses: actions/checkout@v5
        - run: just ci

    """,
]

// MARK: - Benchmarks

print("System at start: \(systemLoad())\n")

let renderer = MarkdownRenderer()
let highlighter = Highlighter()

// Grammars load once per process; the first highlight of each language also loads its grammar.
print("| Language | First highlight (grammar load), ms | 10 000 lines, ms | Lines / ms |")
print("|---|--:|--:|--:|")
for language in CodeLanguage.allCases {
    let load = milliseconds { _ = highlighter.highlight("x", language: language) }
    let file = sourceFile(language, lines: 10_000)
    let time = median(5) { _ = highlighter.highlight(file, language: language) }
    print("| \(language.displayName) | \(format(load)) | \(format(time)) | \(format(10_000 / time)) |")
}

print("\n| Markdown | Characters | Median, ms |")
print("|---|--:|--:|")
for (name, characters) in [("Short answer", 400), ("Typical answer", 1_400), ("Long answer (~4000 tokens)", 16_000)] {
    let markdown = answer(characters: characters)
    let time = median(20) { _ = renderer.render(markdown) }
    print("| \(name) | \(markdown.count) | \(format(time)) |")
}

// Streaming: the long answer in chunks of 13 characters, the average chunk agents send.
let long = answer(characters: 16_000)
var stream = StreamingMarkdown(renderer: renderer)
let text = NSMutableAttributedString()
var chunkTimes: [Double] = []
var rest = Substring(long)
while !rest.isEmpty {
    let chunk = String(rest.prefix(13))
    rest = rest.dropFirst(13)
    chunkTimes.append(milliseconds { stream.append(chunk).apply(to: text) })
}
chunkTimes.sort()
print("\n| Streaming the long answer | Chunks | Total, ms | p50, ms | p95, ms | Max, ms |")
print("|---|--:|--:|--:|--:|--:|")
print(
    "| 13-character chunks | \(chunkTimes.count) | \(format(chunkTimes.reduce(0, +))) "
        + "| \(format(chunkTimes[chunkTimes.count / 2])) | \(format(chunkTimes[chunkTimes.count * 95 / 100])) "
        + "| \(format(chunkTimes.last ?? 0)) |"
)

// Transcript items: rendering many typical answers, as opening a session does.
let items = (0..<1_000).map { answer(characters: 800 + ($0 % 5) * 300) }
let itemsTime = milliseconds {
    for item in items { _ = renderer.render(item) }
}
print("\n| Transcript items | Items | Total, ms | Per item, ms |")
print("|---|--:|--:|--:|")
print("| Typical answers, one thread | \(items.count) | \(format(itemsTime)) | \(format(itemsTime / 1_000)) |")

print("\nSystem at end: \(systemLoad())")
