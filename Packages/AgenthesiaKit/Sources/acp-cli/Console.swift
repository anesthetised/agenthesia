import ACP
import Foundation

/// Serializes everything acp-cli writes to the terminal.
actor Console {
    private var renderer: Renderer

    init(style: Renderer.Style) {
        renderer = Renderer(style: style)
    }

    static func standard() -> Console {
        Console(style: isatty(STDOUT_FILENO) == 1 ? .ansi : .plain)
    }

    func show(_ update: ACP.SessionUpdate) {
        write(renderer.render(update))
    }

    func title(of toolCallId: String) -> String? {
        renderer.title(of: toolCallId)
    }

    func endTurn(_ reason: ACP.StopReason) {
        write(renderer.endTurn(reason))
    }

    func line(_ text: String) {
        write(renderer.lineBreak() + text + "\n")
    }

    func prompt(_ text: String) {
        write(renderer.lineBreak() + text)
    }

    func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private func write(_ text: String) {
        guard !text.isEmpty else { return }
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
