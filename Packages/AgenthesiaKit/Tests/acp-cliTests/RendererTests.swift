import ACP
import JSONRPC
import Testing

@testable import acp_cli

@Suite struct RendererTests {
    private var renderer = Renderer(style: .plain)

    private func chunk(_ text: String) -> ACP.ContentChunk {
        .init(content: .init(text: text))
    }

    @Test mutating func streamsMessagesAndBreaksLinesBetweenKinds() {
        #expect(renderer.render(.agentMessageChunk(chunk("Hel"))) == "Hel")
        #expect(renderer.render(.agentMessageChunk(chunk("lo"))) == "lo")
        #expect(renderer.render(.agentThoughtChunk(chunk("hmm"))) == "\n› hmm")
        #expect(renderer.render(.agentThoughtChunk(chunk("…"))) == "…")
        #expect(renderer.render(.agentMessageChunk(chunk("Done"))) == "\nDone")
        #expect(renderer.endTurn(.endTurn) == "\n— done\n")
        #expect(renderer.endTurn(.cancelled) == "— cancelled\n")
        #expect(renderer.render(.userMessageChunk(chunk("again"))) == "> again\n")
    }

    @Test mutating func rendersToolCallsAndUpdates() {
        let call = ACP.ToolCall(
            toolCallId: "1",
            title: "Edit main.swift",
            kind: .edit,
            status: .pending,
            content: [
                .diff(.init(path: "/a.swift", oldText: "a\nb", newText: "a\nc\nd")),
                .terminal(.init(terminalId: "t")),
                .unknown(["type": "hologram"]),
            ]
        )
        #expect(
            renderer.render(.toolCall(call))
                == """
                ⏺ Edit main.swift · edit · pending
                    ✎ /a.swift (+2 −1)
                    ▸ terminal t
                    (unsupported content)

                """
        )
        #expect(renderer.title(of: "1") == "Edit main.swift")
        #expect(
            renderer.render(.toolCallUpdate(.init(toolCallId: "1", status: .inProgress)))
                == "  ⎿ Edit main.swift running\n"
        )
        #expect(renderer.render(.toolCallUpdate(.init(toolCallId: "1", title: "Renamed"))) == "")
        let output = ACP.ToolCallContent.content(.init(content: .init(text: "1\n2\n3\n4\n5\n")))
        #expect(
            renderer.render(.toolCallUpdate(.init(toolCallId: "1", status: .completed, content: [output])))
                == "  ⎿ Renamed done\n    1\n    2\n    3\n    … 2 more lines\n"
        )
        #expect(renderer.render(.toolCallUpdate(.init(toolCallId: "2", status: .failed))) == "  ⎿ 2 failed\n")
        #expect(
            renderer.render(.toolCallUpdate(.init(toolCallId: "2", status: .unknown("paused")))) == "  ⎿ 2 paused\n"
        )
        #expect(renderer.render(.toolCall(.init(toolCallId: "3", title: "Think"))) == "⏺ Think\n")
    }

    @Test mutating func rendersSessionState() {
        let plan = ACP.Plan(entries: [
            .init(content: "a", priority: .high, status: .completed),
            .init(content: "b", priority: .low, status: .inProgress),
            .init(content: "c", priority: .medium, status: .pending),
        ])
        #expect(renderer.render(.plan(plan)) == "Plan\n  [x] a\n  [~] b\n  [ ] c\n")
        #expect(
            renderer.render(.availableCommands(.init(availableCommands: [.init(name: "web", description: "d")])))
                == "Commands: /web\n"
        )
        #expect(renderer.render(.currentMode(.init(currentModeId: "code"))) == "Mode: code\n")
        #expect(renderer.render(.sessionInfo(.init(title: "Refactor"))) == "Title: Refactor\n")
        #expect(renderer.render(.sessionInfo(.init(updatedAt: "now"))) == "")
        #expect(renderer.render(.unknown(["sessionUpdate": "weather"])) == "(unsupported update weather)\n")
        #expect(
            renderer.render(.usage(.init(used: 1500, size: 200_000, cost: .init(amount: 0.126, currency: "USD"))))
                == "Context: 1.5k / 200k tokens (1%) · 0.13 USD\n"
        )
        #expect(renderer.render(.usage(.init(used: 10, size: 0))) == "Context: 10 / 0 tokens (0%)\n")
        let options: [ACP.ConfigOption] = [
            .init(
                id: "m",
                name: "Model",
                value: .select(currentValue: "l", options: .flat([.init(value: "l", name: "Large")]))
            ),
            .init(id: "x", name: "Other", value: .select(currentValue: "raw", options: .flat([]))),
            .init(id: "w", name: "Web", value: .boolean(currentValue: true)),
            .init(id: "o", name: "Off", value: .boolean(currentValue: false)),
            .init(id: "s", name: "Slider", value: .unknown(type: "slider", raw: nil)),
        ]
        #expect(
            renderer.render(.configOptions(.init(configOptions: options)))
                == "Options: Model=Large, Other=raw, Web=on, Off=off, Slider=(slider)\n"
        )
    }

    @Test mutating func describesNonTextContent() {
        let blocks: [(ACP.ContentBlock, String)] = [
            (.image(.init(data: "", mimeType: "image/png")), "[image image/png]"),
            (.audio(.init(data: "", mimeType: "audio/wav")), "[audio audio/wav]"),
            (.resourceLink(.init(uri: "file:///a", name: "a")), "[a](file:///a)"),
            (.resource(.init(resource: .text(.init(uri: "u", text: "inline")))), "inline"),
            (.resource(.init(resource: .blob(.init(uri: "file:///b", blob: "")))), "[file:///b]"),
            (.resource(.init(resource: .unknown(["uri": "x"]))), "[resource]"),
            (.unknown(["type": "x"]), "[unsupported content]"),
        ]
        for (block, expected) in blocks {
            var renderer = Renderer(style: .plain)
            #expect(renderer.render(.agentMessageChunk(.init(content: block))) == expected)
        }
    }

    @Test func describesStopReasons() {
        #expect(Renderer.describe(.maxTokens) == "stopped: token limit")
        #expect(Renderer.describe(.maxTurnRequests) == "stopped: request limit")
        #expect(Renderer.describe(.refusal) == "refused")
        #expect(Renderer.describe(.unknown("paused")) == "stopped: paused")
        #expect(Renderer.lineChanges(from: "", to: "") == (0, 0))
    }

    @Test func styledOutputUsesANSI() {
        var renderer = Renderer(style: .ansi)
        #expect(renderer.render(.currentMode(.init(currentModeId: "x"))) == "\u{1B}[2mMode: x\u{1B}[0m\n")
        #expect(renderer.render(.userMessageChunk(.init(content: .init(text: "")))) == "\u{1B}[1m> \u{1B}[0m\n")
    }
}

@Suite struct PermissionPromptTests {
    let options: [ACP.PermissionOption] = [
        .init(optionId: "allow", name: "Allow once", kind: .allowOnce),
        .init(optionId: "reject", name: "Reject", kind: .rejectOnce),
    ]

    @Test func rendersNumberedOptions() {
        #expect(
            PermissionPrompt.render(title: "Write a", options: options)
                == "\nPermission requested: Write a\n  1) Allow once\n  2) Reject\nChoose: "
        )
    }

    @Test func parsesNumbersIdsAndNames() {
        #expect(PermissionPrompt.parse("1", options: options) == .selected("allow"))
        #expect(PermissionPrompt.parse(" 2 ", options: options) == .selected("reject"))
        #expect(PermissionPrompt.parse("reject", options: options) == .selected("reject"))
        #expect(PermissionPrompt.parse("allow ONCE", options: options) == .selected("allow"))
        #expect(PermissionPrompt.parse("3", options: options) == nil)
        #expect(PermissionPrompt.parse("0", options: options) == nil)
        #expect(PermissionPrompt.parse("maybe", options: options) == nil)
    }
}
