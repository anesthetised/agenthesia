import AppKit
import Observation
import Rendering

/// Temporary presentation state for the demo; never launches an agent or saves a session.
@Observable
final class DemoSession {
    struct Message {
        let role: String
        var markdown: String
        var text: NSAttributedString
    }

    private(set) var messages: [Message] = []
    private(set) var revision = 0
    private(set) var turn: UUID?
    private(set) var lastUpdate: StreamingMarkdown.Update?
    private var stream = StreamingMarkdown()
    private var task: Task<Void, Never>?
    private let renderer = MarkdownRenderer()

    init() {
        append(role: "You", markdown: "Show me how this session works.")
        append(
            role: "Demo assistant",
            markdown: """
                ## A quiet place to work

                This is a **demo session**. Try a prompt below to see a deterministic response stream.

                - Select and copy text, including code.
                - Scroll up while a response arrives; your place is preserved.
                - Use **Stop** or **⌘.** to interrupt a response.

                ```swift
                let session = "Demo session"
                print(session)
                ```

                No agent is connected. Nothing is saved or changed on disk.
                """
        )
    }

    var isStreaming: Bool { turn != nil }

    /// Starts a turn synchronously; the token also rejects delayed chunks after Stop.
    @discardableResult
    func begin(_ prompt: String) -> UUID? {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, turn == nil else { return nil }
        append(role: "You", markdown: prompt)
        append(role: "Demo assistant", markdown: "")
        stream = StreamingMarkdown(renderer: renderer)
        let token = UUID()
        turn = token
        return token
    }

    func send(_ prompt: String) {
        guard let token = begin(prompt) else { return }
        let chunks = Self.responseChunks
        task = Task { [weak self] in
            for chunk in chunks {
                do { try await Task.sleep(for: .milliseconds(55)) } catch { return }
                guard let self, self.turn == token else { return }
                self.receive(chunk, for: token)
            }
            self?.finish(token)
        }
    }

    func receive(_ chunk: String, for token: UUID) {
        guard turn == token else { return }
        let update = stream.append(chunk)
        let text = NSMutableAttributedString(attributedString: messages[messages.count - 1].text)
        update.apply(to: text)
        messages[messages.count - 1].markdown += chunk
        messages[messages.count - 1].text = text
        lastUpdate = update
        revision += 1
    }

    func finish(_ token: UUID) {
        guard turn == token else { return }
        turn = nil
        task = nil
        lastUpdate = nil
        revision += 1
    }

    func stop() {
        guard let token = turn else { return }
        task?.cancel()
        receive("\n\n*Demo response stopped.*", for: token)
        finish(token)
    }

    private func append(role: String, markdown: String) {
        let text: NSAttributedString =
            role == "You"
            ? NSAttributedString(
                string: markdown,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor,
                ]
            ) : renderer.render(markdown)
        messages.append(Message(role: role, markdown: markdown, text: text))
        lastUpdate = nil
        revision += 1
    }

    static var responseChunks: [String] {
        let response = """
            ## Demo response

            Your prompt is shown above. This response is a fixed sample, so you can evaluate the interface consistently.

            ### A small plan

            1. Understand the request.
            2. Make the smallest useful change.
            3. Check the result and explain it.

            ```swift
            struct Greeting {
                let message = "Hello from Agenthesia"
            }
            ```

            You can select this Markdown, copy a message, or scroll back while it streams.

            **Demo complete.** No agent ran, no files changed, and this conversation lasts only until the window closes.
            """
        var chunks: [String] = []
        var start = response.startIndex
        while start < response.endIndex {
            let end = response.index(start, offsetBy: 12, limitedBy: response.endIndex) ?? response.endIndex
            chunks.append(String(response[start..<end]))
            start = end
        }
        return chunks
    }
}
