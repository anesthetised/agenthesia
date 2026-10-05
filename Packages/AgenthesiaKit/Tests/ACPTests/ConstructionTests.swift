import ACP
import JSONRPC
import Testing

/// Builds values through their initializers and checks the JSON they produce on the wire.
@Suite struct ConstructionTests {
    private let meta: ACP.Meta = ["k": "v"]

    private func expectJSON(
        _ value: some Encodable,
        _ json: JSONValue,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(try JSONValue(encoding: value) == json, sourceLocation: sourceLocation)
    }

    @Test func capabilities() throws {
        try expectJSON(
            ACP.V1.ClientCapabilities(
                fs: .init(readTextFile: true, writeTextFile: false, meta: meta),
                terminal: true,
                session: .init(configOptions: .init(boolean: .init(), meta: meta), meta: meta),
                auth: .init(terminal: true, meta: meta),
                elicitation: .init(form: .init(), url: .init(meta: meta), meta: meta),
                meta: meta
            ),
            [
                "fs": ["readTextFile": true, "writeTextFile": false, "_meta": ["k": "v"]],
                "terminal": true,
                "session": ["configOptions": ["boolean": [:], "_meta": ["k": "v"]], "_meta": ["k": "v"]],
                "auth": ["terminal": true, "_meta": ["k": "v"]],
                "elicitation": ["form": [:], "url": ["_meta": ["k": "v"]], "_meta": ["k": "v"]],
                "_meta": ["k": "v"],
            ]
        )
        try expectJSON(
            ACP.V1.AgentCapabilities(
                loadSession: true,
                promptCapabilities: .init(image: true, audio: false, embeddedContext: true, meta: meta),
                mcpCapabilities: .init(http: true, sse: false, meta: meta),
                sessionCapabilities: .init(
                    list: .init(),
                    delete: .init(),
                    additionalDirectories: .init(),
                    resume: .init(),
                    close: .init(),
                    meta: meta
                ),
                auth: .init(logout: .init(), meta: meta),
                meta: meta
            ),
            [
                "loadSession": true,
                "promptCapabilities": ["image": true, "audio": false, "embeddedContext": true, "_meta": ["k": "v"]],
                "mcpCapabilities": ["http": true, "sse": false, "_meta": ["k": "v"]],
                "sessionCapabilities": [
                    "list": [:], "delete": [:], "additionalDirectories": [:], "resume": [:], "close": [:],
                    "_meta": ["k": "v"],
                ],
                "auth": ["logout": [:], "_meta": ["k": "v"]],
                "_meta": ["k": "v"],
            ]
        )
    }

    @Test func lifecycleMessages() throws {
        let info = ACP.Implementation(name: "agenthesia", title: "Agenthesia", version: "0.1.0", meta: meta)
        try expectJSON(
            ACP.V1.InitializeRequest(protocolVersion: 1, clientCapabilities: .init(), clientInfo: info, meta: meta),
            [
                "protocolVersion": 1, "clientCapabilities": [:],
                "clientInfo": ["name": "agenthesia", "title": "Agenthesia", "version": "0.1.0", "_meta": ["k": "v"]],
                "_meta": ["k": "v"],
            ]
        )
        try expectJSON(
            ACP.V1.InitializeResponse(
                protocolVersion: 1,
                agentCapabilities: .init(),
                authMethods: [.agent(.init(id: "a", name: "A", description: "d", meta: meta))],
                agentInfo: ACP.Implementation(name: "agent", version: "1"),
                meta: meta
            ),
            [
                "protocolVersion": 1, "agentCapabilities": [:],
                "authMethods": [["id": "a", "name": "A", "description": "d", "_meta": ["k": "v"]]],
                "agentInfo": ["name": "agent", "version": "1"], "_meta": ["k": "v"],
            ]
        )
        try expectJSON(ACP.V1.AuthenticateRequest(methodId: "a", meta: meta), ["methodId": "a", "_meta": ["k": "v"]])
        try expectJSON(ACP.V1.EmptyMessage(meta: meta), ["_meta": ["k": "v"]])
        try expectJSON(
            ACP.AuthMethod.terminal(
                .init(id: "t", name: "T", description: "d", args: ["-l"], env: ["A": "1"], meta: meta)
            ),
            [
                "type": "terminal", "id": "t", "name": "T", "description": "d", "args": ["-l"], "env": ["A": "1"],
                "_meta": ["k": "v"],
            ]
        )
    }

    @Test func sessionMessages() throws {
        let stdio = ACP.MCPServer.stdio(
            .init(
                name: "fs",
                command: "/bin/fs",
                args: ["-v"],
                env: [.init(name: "K", value: "V", meta: meta)],
                meta: meta
            )
        )
        let http = ACP.MCPServer.http(
            .init(name: "h", url: "https://x", headers: [.init(name: "A", value: "B")], meta: meta)
        )
        try expectJSON(
            ACP.V1.NewSessionRequest(cwd: "/p", additionalDirectories: ["/q"], mcpServers: [stdio, http], meta: meta),
            [
                "cwd": "/p", "additionalDirectories": ["/q"],
                "mcpServers": [
                    [
                        "name": "fs", "command": "/bin/fs", "args": ["-v"],
                        "env": [["name": "K", "value": "V", "_meta": ["k": "v"]]], "_meta": ["k": "v"],
                    ],
                    [
                        "type": "http", "name": "h", "url": "https://x", "headers": [["name": "A", "value": "B"]],
                        "_meta": ["k": "v"],
                    ],
                ],
                "_meta": ["k": "v"],
            ]
        )
        let modes = ACP.V1.SessionModeState(
            currentModeId: "ask",
            availableModes: [.init(id: "ask", name: "Ask", description: "Asks first", meta: meta)],
            meta: meta
        )
        let option = ACP.ConfigOption(
            id: "web",
            name: "Web",
            description: "Search",
            category: .unknown("x"),
            value: .boolean(currentValue: false),
            meta: meta
        )
        let modesJSON: JSONValue = [
            "currentModeId": "ask",
            "availableModes": [["id": "ask", "name": "Ask", "description": "Asks first", "_meta": ["k": "v"]]],
            "_meta": ["k": "v"],
        ]
        let optionJSON: JSONValue = [
            "id": "web", "name": "Web", "description": "Search", "category": "x", "type": "boolean",
            "currentValue": false, "_meta": ["k": "v"],
        ]
        try expectJSON(
            ACP.V1.NewSessionResponse(sessionId: "s", modes: modes, configOptions: [option], meta: meta),
            ["sessionId": "s", "modes": modesJSON, "configOptions": [optionJSON], "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.V1.LoadSessionRequest(
                sessionId: "s",
                cwd: "/p",
                additionalDirectories: ["/q"],
                mcpServers: [],
                meta: meta
            ),
            ["sessionId": "s", "cwd": "/p", "additionalDirectories": ["/q"], "mcpServers": [], "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.V1.ResumeSessionRequest(
                sessionId: "s",
                cwd: "/p",
                additionalDirectories: nil,
                mcpServers: [],
                meta: meta
            ),
            ["sessionId": "s", "cwd": "/p", "mcpServers": [], "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.V1.SessionStateResponse(modes: modes, configOptions: [option], meta: meta),
            ["modes": modesJSON, "configOptions": [optionJSON], "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.V1.ListSessionsRequest(cwd: "/p", cursor: "c", meta: meta),
            ["cwd": "/p", "cursor": "c", "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.V1.ListSessionsResponse(
                sessions: [
                    .init(
                        sessionId: "s",
                        cwd: "/p",
                        additionalDirectories: ["/q"],
                        title: "T",
                        updatedAt: "2026-10-05T00:00:00Z",
                        meta: meta
                    )
                ],
                nextCursor: "n",
                meta: meta
            ),
            [
                "sessions": [
                    [
                        "sessionId": "s", "cwd": "/p", "additionalDirectories": ["/q"], "title": "T",
                        "updatedAt": "2026-10-05T00:00:00Z", "_meta": ["k": "v"],
                    ]
                ],
                "nextCursor": "n", "_meta": ["k": "v"],
            ]
        )
        try expectJSON(ACP.V1.SessionRequest(sessionId: "s", meta: meta), ["sessionId": "s", "_meta": ["k": "v"]])
        try expectJSON(
            ACP.V1.SetModeRequest(sessionId: "s", modeId: "code", meta: meta),
            ["sessionId": "s", "modeId": "code", "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.V1.SetConfigOptionRequest(sessionId: "s", configId: "web", value: .boolean(true), meta: meta),
            ["sessionId": "s", "configId": "web", "type": "boolean", "value": true, "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.V1.SetConfigOptionResponse(configOptions: [option], meta: meta),
            ["configOptions": [optionJSON], "_meta": ["k": "v"]]
        )
    }

    @Test func promptMessages() throws {
        try expectJSON(
            ACP.V1.PromptRequest(
                sessionId: "s",
                prompt: [
                    .text(
                        .init(
                            text: "hi",
                            annotations: .init(audience: [.user], lastModified: "x", priority: 1, meta: meta),
                            meta: meta
                        )
                    ),
                    .image(.init(data: "AA==", mimeType: "image/png", uri: "file:///a", annotations: nil, meta: meta)),
                    .audio(.init(data: "AA==", mimeType: "audio/wav", annotations: nil, meta: meta)),
                    .resourceLink(
                        .init(
                            uri: "file:///b",
                            name: "b",
                            title: "B",
                            description: "d",
                            mimeType: "text/plain",
                            size: 3,
                            annotations: nil,
                            meta: meta
                        )
                    ),
                    .resource(
                        .init(
                            resource: .blob(.init(uri: "file:///c", blob: "AA==", mimeType: "image/png", meta: meta)),
                            annotations: nil,
                            meta: meta
                        )
                    ),
                ],
                meta: meta
            ),
            [
                "sessionId": "s",
                "prompt": [
                    [
                        "type": "text", "text": "hi", "_meta": ["k": "v"],
                        "annotations": [
                            "audience": ["user"], "lastModified": "x", "priority": 1.0, "_meta": ["k": "v"],
                        ],
                    ],
                    [
                        "type": "image", "data": "AA==", "mimeType": "image/png", "uri": "file:///a",
                        "_meta": ["k": "v"],
                    ],
                    ["type": "audio", "data": "AA==", "mimeType": "audio/wav", "_meta": ["k": "v"]],
                    [
                        "type": "resource_link", "uri": "file:///b", "name": "b", "title": "B", "description": "d",
                        "mimeType": "text/plain", "size": 3, "_meta": ["k": "v"],
                    ],
                    [
                        "type": "resource", "_meta": ["k": "v"],
                        "resource": ["uri": "file:///c", "blob": "AA==", "mimeType": "image/png", "_meta": ["k": "v"]],
                    ],
                ],
                "_meta": ["k": "v"],
            ]
        )
        try expectJSON(
            ACP.V1.PromptResponse(stopReason: .refusal, meta: meta),
            ["stopReason": "refusal", "_meta": ["k": "v"]]
        )
    }

    @Test func sessionUpdates() throws {
        let toolCall = ACP.ToolCall(
            toolCallId: "1",
            title: "Edit",
            name: "edit",
            kind: .edit,
            status: .inProgress,
            content: [
                .content(.init(content: .init(text: "x"), meta: meta)),
                .diff(.init(path: "/a", oldText: "o", newText: "n", meta: meta)),
                .terminal(.init(terminalId: "t", meta: meta)),
            ],
            locations: [.init(path: "/a", line: 2, meta: meta)],
            rawInput: ["a": 1],
            rawOutput: ["b": 2],
            meta: meta
        )
        try expectJSON(
            ACP.V1.SessionNotification(sessionId: "s", update: .toolCall(toolCall), meta: meta),
            [
                "sessionId": "s", "_meta": ["k": "v"],
                "update": [
                    "sessionUpdate": "tool_call", "toolCallId": "1", "title": "Edit", "name": "edit", "kind": "edit",
                    "status": "in_progress", "rawInput": ["a": 1], "rawOutput": ["b": 2], "_meta": ["k": "v"],
                    "locations": [["path": "/a", "line": 2, "_meta": ["k": "v"]]],
                    "content": [
                        ["type": "content", "content": ["type": "text", "text": "x"], "_meta": ["k": "v"]],
                        ["type": "diff", "path": "/a", "oldText": "o", "newText": "n", "_meta": ["k": "v"]],
                        ["type": "terminal", "terminalId": "t", "_meta": ["k": "v"]],
                    ],
                ],
            ]
        )
        let updates: [(ACP.SessionUpdate, JSONValue)] = [
            (
                .userMessageChunk(.init(content: .init(text: "u"), messageId: "m", meta: meta)),
                [
                    "sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "u"], "messageId": "m",
                    "_meta": ["k": "v"],
                ]
            ),
            (
                .agentThoughtChunk(.init(content: .init(text: "t"))),
                ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "t"]]
            ),
            (
                .toolCallUpdate(
                    .init(
                        toolCallId: "1",
                        title: "T",
                        name: "n",
                        kind: .read,
                        status: .failed,
                        content: [],
                        locations: [],
                        rawInput: nil,
                        rawOutput: "x",
                        meta: meta
                    )
                ),
                [
                    "sessionUpdate": "tool_call_update", "toolCallId": "1", "title": "T", "name": "n", "kind": "read",
                    "status": "failed", "content": [], "locations": [], "rawOutput": "x", "_meta": ["k": "v"],
                ]
            ),
            (
                .plan(
                    .init(entries: [.init(content: "c", priority: .low, status: .completed, meta: meta)], meta: meta)
                ),
                [
                    "sessionUpdate": "plan", "_meta": ["k": "v"],
                    "entries": [["content": "c", "priority": "low", "status": "completed", "_meta": ["k": "v"]]],
                ]
            ),
            (
                .availableCommands(
                    .init(
                        availableCommands: [
                            .init(name: "w", description: "d", input: .init(hint: "h", meta: meta), meta: meta)
                        ],
                        meta: meta
                    )
                ),
                [
                    "sessionUpdate": "available_commands_update", "_meta": ["k": "v"],
                    "availableCommands": [
                        [
                            "name": "w", "description": "d", "input": ["hint": "h", "_meta": ["k": "v"]],
                            "_meta": ["k": "v"],
                        ]
                    ],
                ]
            ),
            (
                .currentMode(.init(currentModeId: "code", meta: meta)),
                ["sessionUpdate": "current_mode_update", "currentModeId": "code", "_meta": ["k": "v"]]
            ),
            (
                .configOptions(.init(configOptions: [], meta: meta)),
                ["sessionUpdate": "config_option_update", "configOptions": [], "_meta": ["k": "v"]]
            ),
            (
                .sessionInfo(.init(title: "T", updatedAt: "now", meta: meta)),
                ["sessionUpdate": "session_info_update", "title": "T", "updatedAt": "now", "_meta": ["k": "v"]]
            ),
            (
                .usage(.init(used: 1, size: 2, cost: .init(amount: 0.25, currency: "EUR", meta: meta), meta: meta)),
                [
                    "sessionUpdate": "usage_update", "used": 1, "size": 2, "_meta": ["k": "v"],
                    "cost": ["amount": 0.25, "currency": "EUR", "_meta": ["k": "v"]],
                ]
            ),
        ]
        for (update, json) in updates {
            try expectJSON(update, json)
        }
    }

    @Test func clientRequests() throws {
        try expectJSON(
            ACP.V1.RequestPermissionRequest(
                sessionId: "s",
                toolCall: .init(toolCallId: "1"),
                options: [.init(optionId: "o", name: "Allow", kind: .allowOnce, meta: meta)],
                meta: meta
            ),
            [
                "sessionId": "s", "toolCall": ["toolCallId": "1"], "_meta": ["k": "v"],
                "options": [["optionId": "o", "name": "Allow", "kind": "allow_once", "_meta": ["k": "v"]]],
            ]
        )
        try expectJSON(
            ACP.V1.RequestPermissionResponse(outcome: .selected("o"), meta: meta),
            ["outcome": ["outcome": "selected", "optionId": "o"], "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.V1.ReadTextFileRequest(sessionId: "s", path: "/a", line: 1, limit: 5, meta: meta),
            ["sessionId": "s", "path": "/a", "line": 1, "limit": 5, "_meta": ["k": "v"]]
        )
        try expectJSON(ACP.V1.ReadTextFileResponse(content: "x", meta: meta), ["content": "x", "_meta": ["k": "v"]])
        try expectJSON(
            ACP.V1.WriteTextFileRequest(sessionId: "s", path: "/a", content: "x", meta: meta),
            ["sessionId": "s", "path": "/a", "content": "x", "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.V1.CreateTerminalRequest(
                sessionId: "s",
                command: "ls",
                args: ["-l"],
                env: [.init(name: "A", value: "1")],
                cwd: "/p",
                outputByteLimit: 1024,
                meta: meta
            ),
            [
                "sessionId": "s", "command": "ls", "args": ["-l"], "env": [["name": "A", "value": "1"]], "cwd": "/p",
                "outputByteLimit": 1024, "_meta": ["k": "v"],
            ]
        )
        try expectJSON(
            ACP.V1.CreateTerminalResponse(terminalId: "t", meta: meta),
            ["terminalId": "t", "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.V1.TerminalRequest(sessionId: "s", terminalId: "t", meta: meta),
            ["sessionId": "s", "terminalId": "t", "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.V1.TerminalOutputResponse(
                output: "o",
                truncated: true,
                exitStatus: .init(exitCode: 1, signal: "SIGTERM", meta: meta),
                meta: meta
            ),
            [
                "output": "o", "truncated": true, "_meta": ["k": "v"],
                "exitStatus": ["exitCode": 1, "signal": "SIGTERM", "_meta": ["k": "v"]],
            ]
        )
    }

    @Test func elicitation() throws {
        let schema = ACP.ElicitationSchema(
            title: "T",
            description: "D",
            properties: [
                "s": .string(
                    .init(
                        title: "S",
                        description: "d",
                        minLength: 1,
                        maxLength: 9,
                        pattern: ".*",
                        format: .uri,
                        default: "x",
                        enum: ["x"],
                        oneOf: [.init(const: "x", title: "X", description: "d", meta: meta)],
                        meta: meta
                    )
                ),
                "n": .number(.init(title: "N", description: "d", minimum: 0, maximum: 1, default: 0.5, meta: meta)),
                "i": .integer(.init(minimum: 1)),
                "b": .boolean(.init(title: "B", description: "d", default: true, meta: meta)),
                "m": .multiSelect(
                    .init(
                        title: "M",
                        description: "d",
                        minItems: 1,
                        maxItems: 2,
                        items: .titled([.init(const: "a", title: "A")]),
                        default: ["a"],
                        meta: meta
                    )
                ),
                "ms": .multiSelect(.init(items: .strings(["a", "b"]))),
            ],
            required: ["s"],
            meta: meta
        )
        let request = ACP.ElicitationRequest(
            message: "m",
            mode: .form(schema),
            scope: .session("s", toolCallId: nil),
            meta: meta
        )
        let encoded = try JSONValue(encoding: request)
        #expect(try encoded.decode(as: ACP.ElicitationRequest.self) == request)
        #expect(encoded["requestedSchema"]?["properties"]?["m"]?["type"] == "array")
        #expect(encoded["requestedSchema"]?["properties"]?["ms"]?["items"] == ["type": "string", "enum": ["a", "b"]])
        try expectJSON(
            ACP.ElicitationResponse(action: .accept(nil), meta: meta),
            ["action": "accept", "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.ElicitationComplete(elicitationId: "e", meta: meta),
            ["elicitationId": "e", "_meta": ["k": "v"]]
        )
    }

    @Test func remainingInitializers() throws {
        try expectJSON(
            ACP.EmbeddedResource(resource: .text(.init(uri: "u", text: "t")), annotations: .init(), meta: meta),
            ["resource": ["uri": "u", "text": "t"], "annotations": [:], "_meta": ["k": "v"]]
        )
        try expectJSON(
            ACP.MCPServer.sse(.init(name: "s", url: "https://s")),
            ["type": "sse", "name": "s", "url": "https://s", "headers": []]
        )
        try expectJSON(
            ACP.ConfigSelectGroup(
                group: "g",
                name: "G",
                options: [.init(value: "v", name: "V", description: "d", meta: meta)],
                meta: meta
            ),
            [
                "group": "g", "name": "G", "_meta": ["k": "v"],
                "options": [["value": "v", "name": "V", "description": "d", "_meta": ["k": "v"]]],
            ]
        )
        try expectJSON(ACP.Capability(meta: meta), ["_meta": ["k": "v"]])
        try expectJSON(
            ACP.ToolCall(toolCallId: "1", title: "T"),
            ["toolCallId": "1", "title": "T"]
        )
        try expectJSON(
            ACP.TextResourceContents(uri: "u", text: "t", mimeType: "m", meta: meta),
            ["uri": "u", "text": "t", "mimeType": "m", "_meta": ["k": "v"]]
        )
    }
}
