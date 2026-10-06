#if DEBUG
    import Foundation

    /// A deterministic synthetic transcript: the same seed always gives the same items.
    struct TranscriptGenerator {
        enum Item {
            case user(String)
            case assistant(markdown: String)
            case toolCall(title: String, output: String)
            case diff(path: String, patch: String)
        }

        private var random: SplitMix64

        init(seed: UInt64) {
            random = SplitMix64(seed: seed)
        }

        mutating func items(_ count: Int) -> [Item] {
            (0..<count).map { index in
                switch index % 4 {
                case 0: .user(sentences(Int.random(in: 1...3, using: &random)))
                case 1: .assistant(markdown: answer(tokens: Int.random(in: 80...600, using: &random)))
                case 2: .toolCall(title: pick(Self.tools), output: pick(Self.outputs))
                default: .diff(path: pick(Self.paths), patch: diff())
                }
            }
        }

        /// A Markdown answer of about `tokens` tokens (four characters each), with headings, lists and code.
        mutating func answer(tokens: Int) -> String {
            var parts: [String] = []
            var length = 0
            while length < tokens * 4 {
                let part =
                    switch Int.random(in: 0..<10, using: &random) {
                    case 0: "## \(pick(Self.words).capitalized) \(pick(Self.words))"
                    case 1, 2:
                        (0..<Int.random(in: 2...5, using: &random)).map { _ in "- \(sentences(1))" }
                            .joined(separator: "\n")
                    case 3, 4: code()
                    case 5: "> \(sentences(2))"
                    default: sentences(Int.random(in: 2...5, using: &random))
                    }
                parts.append(part)
                length += part.count
            }
            return parts.joined(separator: "\n\n")
        }

        /// `text` cut into chunks of 2–24 characters, the size agents stream.
        mutating func chunks(of text: String) -> [String] {
            var chunks: [String] = []
            var rest = Substring(text)
            while !rest.isEmpty {
                let length = Int.random(in: 2...24, using: &random)
                chunks.append(String(rest.prefix(length)))
                rest = rest.dropFirst(length)
            }
            return chunks
        }

        /// A Swift source file of `lines` lines.
        static func swiftFile(lines: Int) -> String {
            var result: [String] = []
            var index = 0
            while result.count < lines {
                result += [
                    "/// Handles case \(index) of the protocol.",
                    "struct Handler\(index): Sendable {",
                    "    let name = \"handler-\(index)\"",
                    "    var count: Int = \(index)",
                    "",
                    "    func process(_ input: [String]) -> Int {",
                    "        input.filter { $0.hasPrefix(name) }.count + count  // \(index * 7)",
                    "    }",
                    "}",
                    "",
                ]
                index += 1
            }
            return result.prefix(lines).joined(separator: "\n")
        }

        // MARK: - Pieces

        private mutating func pick<T>(_ values: [T]) -> T {
            values[Int.random(in: 0..<values.count, using: &random)]
        }

        private mutating func sentences(_ count: Int) -> String {
            (0..<count).map { _ in
                let words = (0..<Int.random(in: 6...16, using: &random)).map { _ in pick(Self.words) }
                var sentence = words.joined(separator: " ")
                if Bool.random(using: &random) { sentence += " `\(pick(Self.identifiers))`" }
                if Int.random(in: 0..<4, using: &random) == 0 { sentence += " **\(pick(Self.words))**" }
                return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
            }.joined(separator: " ")
        }

        private mutating func code() -> String {
            let (language, snippet) = pick(Self.snippets)
            return "```\(language)\n\(snippet)\n```"
        }

        private mutating func diff() -> String {
            let name = pick(Self.identifiers)
            return """
                @@ -12,7 +12,8 @@
                 func \(name)() {
                -    let value = compute()
                +    let value = try compute()
                +    guard value > 0 else { return }
                     print(value)
                 }
                """
        }

        private static let words = """
            the agent reads file then writes change because session tool output stream render layout view text \
            protocol message request response buffer token block list table code line scroll frame cache update
            """.split(separator: " ").map(String.init)

        private static let identifiers = ["sessionID", "render()", "TextKit", "NSTableView", "prompt", "LineFramer"]
        private static let tools = [
            "Read Sources/App.swift", "Run swift test", "Search for \"render\"", "Edit README.md",
        ]
        private static let outputs = [
            "Build complete! (12.4s)", "42 tests passed", "Found 7 matches in 3 files", "File updated",
        ]
        private static let paths = ["Sources/Rendering/Theme.swift", "Package.swift", "App/AgenthesiaApp.swift"]

        private static let snippets: [(String, String)] = [
            (
                "swift",
                """
                func render(_ text: String) async throws -> NSAttributedString {
                    let document = Document(parsing: text)
                    return try await renderer.render(document) // cached
                }
                """
            ),
            (
                "ts",
                """
                export async function load(id: string): Promise<Session> {
                  const response = await fetch(`/sessions/${id}`);
                  return (await response.json()) as Session;
                }
                """
            ),
            (
                "python",
                """
                def frames(times: list[float]) -> float:
                    # p95 of the frame times
                    return sorted(times)[int(len(times) * 0.95)]
                """
            ),
            ("bash", "swift build -c release && ./.build/release/rendering-bench --iterations 100"),
            ("json", "{\n  \"name\": \"agenthesia\",\n  \"version\": 2,\n  \"enabled\": true\n}"),
        ]
    }

    /// A small deterministic random number generator.
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
#endif
