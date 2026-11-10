import ACP
import JSONRPC
import Testing

@testable import AgenthesiaCore

/// The command of a shell call's permission request (#375). No recorded traffic of the agents is kept in the
/// repository, so each fixture is the shape the agent is known to send, built from the ACP schema.
struct PermissionCommandTests {
    private func call(
        title: String = "",
        kind: ACP.ToolKind? = .execute,
        content: [ACP.ToolCallContent]? = nil,
        rawInput: JSONValue? = nil
    ) -> ACP.ToolCall {
        .init(toolCallId: "run", title: title, kind: kind, content: content, rawInput: rawInput)
    }

    private func text(_ text: String) -> ACP.ToolCallContent { .content(.init(content: .init(text: text))) }

    private let loop = "for n in 45 46 47; do echo $n; done"

    // MARK: - Recorded shapes

    /// Claude: the command as `rawInput.command` and in the title, the description as text content.
    @Test func claudeSendsTheCommandAsAString() {
        let claude = call(
            title: "`\(loop)`",
            content: [text("Print three numbers")],
            rawInput: ["command": .string(loop), "description": "Print three numbers"]
        )
        #expect(PermissionCommand.of(claude) == loop)
    }

    /// Codex: an argument array, wrapped in a login shell.
    @Test func codexSendsAnArgumentArrayInAShell() {
        let codex = call(title: "Run \(loop)", rawInput: ["command": ["bash", "-lc", .string(loop)], "cwd": "/tmp"])
        #expect(PermissionCommand.of(codex) == loop)
        let sh = call(rawInput: ["command": ["/bin/sh", "-c", "ls -la"]])
        #expect(PermissionCommand.of(sh) == "ls -la")
    }

    /// Kimi: no `rawInput`; the command is in the text content, behind its own words.
    @Test func kimiSendsOnlyTextContent() {
        let kimi = call(title: "Shell", content: [text("Requesting approval to Running: \(loop)")])
        #expect(PermissionCommand.of(kimi) == "Requesting approval to Running: \(loop)")
    }

    // MARK: - Rules

    @Test func anArgumentArrayIsJoinedWithShellQuoting() {
        let plain = call(rawInput: [
            "command": ["git", "commit", "-m", "fix: it's a bug", "--", "", "a b", "src/x.swift"]
        ])
        #expect(PermissionCommand.of(plain) == "git commit -m 'fix: it'\\''s a bug' -- '' 'a b' src/x.swift")
        // Not a shell wrapper: the program and its arguments stay.
        let script = call(rawInput: ["command": ["bash", "build.sh", "--fast"]])
        #expect(PermissionCommand.of(script) == "bash build.sh --fast")
        // A wrapper with several script words keeps them as separate words.
        let words = call(rawInput: ["command": ["zsh", "-c", "echo", "a b"]])
        #expect(PermissionCommand.of(words) == "echo 'a b'")
    }

    @Test func theSourcesAreTriedInOrder() {
        let all = call(
            title: "Title",
            content: [.diff(.init(path: "a", oldText: nil, newText: "")), text("Content")],
            rawInput: ["command": "raw"]
        )
        #expect(PermissionCommand.of(all) == "raw")
        // Not a string or an array of strings: the next source.
        #expect(
            PermissionCommand.of(call(title: "Title", content: [text("Content")], rawInput: ["command": 3]))
                == "Content"
        )
        #expect(PermissionCommand.of(call(title: "Title", rawInput: ["command": ["a", 1]])) == "Title")
        #expect(
            PermissionCommand.of(call(title: "Title", content: [.diff(.init(path: "a", oldText: nil, newText: ""))]))
                == "Title"
        )
        // Blank sources are skipped, and the command is trimmed.
        #expect(
            PermissionCommand.of(call(title: "Title", content: [text("  \n")], rawInput: ["command": " ls\n"])) == "ls"
        )
        #expect(PermissionCommand.of(call(title: "Title", content: [text(" ")], rawInput: ["command": ""])) == "Title")
        #expect(PermissionCommand.of(call()) == nil)
    }

    @Test func onlyAShellCallHasACommand() {
        #expect(PermissionCommand.of(call(title: "Write", kind: .edit, rawInput: ["command": "ls"])) == nil)
        #expect(PermissionCommand.of(call(title: "Fetch", kind: nil)) == nil)
    }

    @Test func theFirstLineAndTheBoardCut() {
        #expect(PermissionCommand.firstLine("a\nb") == "a")
        #expect(PermissionCommand.firstLine("\nb") == "b")
        #expect(PermissionCommand.firstLine("one") == "one")
        #expect(!PermissionCommand.isCutOnBoard("a\nb\nc\nd"))
        #expect(PermissionCommand.isCutOnBoard("a\nb\nc\nd\ne"))
        #expect(!PermissionCommand.isCutOnBoard(String(repeating: "x", count: 200)))
        #expect(PermissionCommand.isCutOnBoard(String(repeating: "x", count: 201)))
        // A blank line takes a line.
        #expect(PermissionCommand.isCutOnBoard("a\n\n\n\nb"))
    }
}
