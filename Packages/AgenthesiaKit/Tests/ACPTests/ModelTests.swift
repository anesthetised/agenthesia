import ACP
import Foundation
import JSONRPC
import Testing

@Suite struct OpenEnumTests {
    private func check<E: OpenEnum>(_ type: E.Type) throws {
        for value in E.knownCases {
            let json = JSONValue.string(value.rawValue)
            #expect(try json.decode(as: E.self) == value)
            #expect(try JSONValue(encoding: value) == json)
            #expect(E(rawValue: value.rawValue) == value)
        }
        let unknown = try JSONValue.string("from_the_future").decode(as: E.self)
        #expect(unknown == .unknown("from_the_future"))
        #expect(unknown.rawValue == "from_the_future")
        #expect(try JSONValue(encoding: unknown) == "from_the_future")
    }

    @Test func allEnumsTolerateUnknownValues() throws {
        try check(ACP.Role.self)
        try check(ACP.ToolKind.self)
        try check(ACP.ToolCallStatus.self)
        try check(ACP.PlanEntryPriority.self)
        try check(ACP.PlanEntryStatus.self)
        try check(ACP.PermissionOptionKind.self)
        try check(ACP.StopReason.self)
        try check(ACP.ConfigOptionCategory.self)
        try check(ACP.StringFormat.self)
    }

    @Test func snakeCaseRawValues() {
        #expect(ACP.ToolKind.switchMode.rawValue == "switch_mode")
        #expect(ACP.ToolCallStatus.inProgress.rawValue == "in_progress")
        #expect(ACP.StopReason.maxTurnRequests.rawValue == "max_turn_requests")
        #expect(ACP.PermissionOptionKind.rejectAlways.rawValue == "reject_always")
        #expect(ACP.ConfigOptionCategory.thoughtLevel.rawValue == "thought_level")
        #expect(ACP.StringFormat.dateTime.rawValue == "date-time")
    }
}

@Suite struct TaggedUnionTests {
    @Test func unknownVariantsArePreserved() throws {
        let future: JSONValue = ["type": "hologram", "data": "x", "depth": 3]
        #expect(try expectRoundTrip(ACP.ContentBlock.self, future) == .unknown(future))
        #expect(try expectRoundTrip(ACP.ToolCallContent.self, future) == .unknown(future))
        #expect(
            try expectRoundTrip(ACP.MCPServer.self, ["type": "ws", "name": "n"])
                == .unknown(["type": "ws", "name": "n"])
        )
        #expect(try expectRoundTrip(ACP.AuthMethod.self, ["type": "oauth", "id": "o"]).id == "o")
        #expect(
            try expectRoundTrip(ACP.PropertySchema.self, ["type": "date", "title": "t"])
                == .unknown(["type": "date", "title": "t"])
        )
        #expect(try expectRoundTrip(ACP.ResourceContents.self, ["uri": "u"]) == .unknown(["uri": "u"]))
        #expect(try expectRoundTrip(ACP.MultiSelectItems.self, ["type": "number"]) == .unknown(["type": "number"]))
        let outcome: JSONValue = ["outcome": "deferred", "until": 5]
        #expect(try expectRoundTrip(ACP.PermissionOutcome.self, outcome) == .unknown(outcome))
        let update: JSONValue = ["sessionUpdate": "weather_update", "sunny": true]
        #expect(try expectRoundTrip(ACP.SessionUpdate.self, update) == .unknown(update))
    }

    @Test func knownVariantsWithMissingFieldsFail() {
        #expect(throws: DecodingError.self) { try JSONValue.object(["type": "text"]).decode(as: ACP.ContentBlock.self) }
        #expect(throws: DecodingError.self) {
            try JSONValue.object(["type": "diff", "path": "/a"]).decode(as: ACP.ToolCallContent.self)
        }
        #expect(throws: DecodingError.self) {
            try JSONValue.object(["sessionUpdate": "tool_call", "toolCallId": "1"]).decode(as: ACP.SessionUpdate.self)
        }
        #expect(throws: DecodingError.self) {
            try JSONValue.object(["outcome": "selected"]).decode(as: ACP.PermissionOutcome.self)
        }
    }

    @Test func contentBlocks() throws {
        #expect(ACP.ContentBlock(text: "hi") == .text(ACP.TextContent(text: "hi")))
        try expectRoundTrip(
            ACP.ContentBlock.self,
            ["type": "text", "text": "hi", "annotations": ["audience": ["user"], "priority": 0.5]]
        )
        try expectRoundTrip(
            ACP.ContentBlock.self,
            ["type": "image", "data": "AA==", "mimeType": "image/png", "uri": "file:///a.png"]
        )
        try expectRoundTrip(ACP.ContentBlock.self, ["type": "audio", "data": "AA==", "mimeType": "audio/wav"])
        try expectRoundTrip(
            ACP.ContentBlock.self,
            [
                "type": "resource_link", "uri": "file:///a", "name": "a", "title": "A", "description": "d",
                "mimeType": "text/plain", "size": 12,
            ]
        )
        let text = try expectRoundTrip(
            ACP.ContentBlock.self,
            ["type": "resource", "resource": ["uri": "file:///a", "text": "x", "mimeType": "text/plain"]]
        )
        #expect(text == .resource(.init(resource: .text(.init(uri: "file:///a", text: "x", mimeType: "text/plain")))))
        let blob = try expectRoundTrip(
            ACP.ContentBlock.self,
            ["type": "resource", "resource": ["uri": "file:///b", "blob": "AA=="]]
        )
        #expect(blob == .resource(.init(resource: .blob(.init(uri: "file:///b", blob: "AA==")))))
    }

    @Test func toolCallContent() throws {
        try expectRoundTrip(ACP.ToolCallContent.self, ["type": "content", "content": ["type": "text", "text": "out"]])
        let newFile = try expectRoundTrip(ACP.ToolCallContent.self, ["type": "diff", "path": "/a", "newText": "x"])
        #expect(newFile == .diff(.init(path: "/a", oldText: nil, newText: "x")))
        try expectRoundTrip(ACP.ToolCallContent.self, ["type": "diff", "path": "/a", "oldText": "w", "newText": "x"])
        try expectRoundTrip(ACP.ToolCallContent.self, ["type": "terminal", "terminalId": "t1"])
    }

    @Test func mcpServers() throws {
        try expectRoundTrip(
            ACP.MCPServer.self,
            ["name": "fs", "command": "/bin/fs", "args": ["-v"], "env": [["name": "K", "value": "V"]]]
        )
        try expectRoundTrip(
            ACP.MCPServer.self,
            ["type": "http", "name": "h", "url": "https://x", "headers": [["name": "A", "value": "B"]]]
        )
        try expectRoundTrip(ACP.MCPServer.self, ["type": "sse", "name": "s", "url": "https://y", "headers": []])
    }

    @Test func authMethods() throws {
        let agent = try expectRoundTrip(ACP.AuthMethod.self, ["id": "a", "name": "Agent", "description": "d"])
        #expect(agent.id == "a")
        let explicitAgent = try JSONValue.object(["type": "agent", "id": "a", "name": "Agent"]).decode(
            as: ACP.AuthMethod.self
        )
        #expect(explicitAgent == .agent(.init(id: "a", name: "Agent")))
        let terminal = try expectRoundTrip(
            ACP.AuthMethod.self,
            ["type": "terminal", "id": "t", "name": "Login", "args": ["--login"], "env": ["X": "1"]]
        )
        #expect(terminal.id == "t")
        // Invalid optional fields are ignored instead of failing the whole method.
        let lenient = try JSONValue.object(["type": "terminal", "id": "t", "name": "Login", "args": 5, "env": "x"])
            .decode(as: ACP.AuthMethod.self)
        #expect(lenient == .terminal(.init(id: "t", name: "Login")))
    }

    @Test func permissionOutcomes() throws {
        #expect(try expectRoundTrip(ACP.PermissionOutcome.self, ["outcome": "cancelled"]) == .cancelled)
        #expect(
            try expectRoundTrip(ACP.PermissionOutcome.self, ["outcome": "selected", "optionId": "o"]) == .selected("o")
        )
    }

    @Test func sessionUpdates() throws {
        let chunk: JSONValue = ["type": "text", "text": "x"]
        try expectRoundTrip(
            ACP.SessionUpdate.self,
            ["sessionUpdate": "user_message_chunk", "content": chunk, "messageId": "m"]
        )
        try expectRoundTrip(ACP.SessionUpdate.self, ["sessionUpdate": "agent_message_chunk", "content": chunk])
        try expectRoundTrip(ACP.SessionUpdate.self, ["sessionUpdate": "agent_thought_chunk", "content": chunk])
        try expectRoundTrip(
            ACP.SessionUpdate.self,
            [
                "sessionUpdate": "tool_call", "toolCallId": "1", "title": "Read", "name": "read_file", "kind": "read",
                "status": "pending", "locations": [["path": "/a", "line": 3]], "rawInput": ["path": "/a"],
            ]
        )
        try expectRoundTrip(
            ACP.SessionUpdate.self,
            ["sessionUpdate": "tool_call_update", "toolCallId": "1", "status": "completed", "rawOutput": ["ok": true]]
        )
        try expectRoundTrip(
            ACP.SessionUpdate.self,
            ["sessionUpdate": "plan", "entries": [["content": "a", "priority": "high", "status": "pending"]]]
        )
        try expectRoundTrip(
            ACP.SessionUpdate.self,
            [
                "sessionUpdate": "available_commands_update",
                "availableCommands": [["name": "web", "description": "d", "input": ["hint": "q"]]],
            ]
        )
        try expectRoundTrip(ACP.SessionUpdate.self, ["sessionUpdate": "current_mode_update", "currentModeId": "code"])
        try expectRoundTrip(ACP.SessionUpdate.self, ["sessionUpdate": "config_option_update", "configOptions": []])
        try expectRoundTrip(
            ACP.SessionUpdate.self,
            ["sessionUpdate": "session_info_update", "title": "T", "updatedAt": "2026-10-05T00:00:00Z"]
        )
        try expectRoundTrip(
            ACP.SessionUpdate.self,
            ["sessionUpdate": "usage_update", "used": 10, "size": 100, "cost": ["amount": 0.5, "currency": "USD"]]
        )
    }

    @Test func usageIgnoresInvalidCost() throws {
        let usage = try JSONValue.object(["sessionUpdate": "usage_update", "used": 1, "size": 2, "cost": "free"])
            .decode(as: ACP.SessionUpdate.self)
        #expect(usage == .usage(.init(used: 1, size: 2)))
    }

    @Test func metaPassesThrough() throws {
        let meta: JSONValue = ["traceparent": "00-abc", "vendor.example/flag": ["nested": [1, 2]]]
        let block = try expectRoundTrip(ACP.ContentBlock.self, ["type": "text", "text": "x", "_meta": meta])
        guard case .text(let text) = block else {
            Issue.record("Expected text")
            return
        }
        #expect(text.meta == meta.objectValue)
        try expectRoundTrip(ACP.ToolCallLocation.self, ["path": "/a", "_meta": meta])
        try expectRoundTrip(ACP.V1.PromptResponse.self, ["stopReason": "end_turn", "_meta": meta])
        try expectRoundTrip(ACP.Capability.self, ["_meta": meta])
    }
}

@Suite struct ConfigOptionTests {
    @Test func selectWithFlatOptions() throws {
        let option = try expectRoundTrip(
            ACP.ConfigOption.self,
            [
                "id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "a",
                "options": [["value": "a", "name": "A"], ["value": "b", "name": "B", "description": "Big"]],
            ]
        )
        guard case .select("a", .flat(let options)) = option.value else {
            Issue.record("Unexpected \(option.value)")
            return
        }
        #expect(options.map(\.value) == ["a", "b"])
        #expect(option.category == .model)
    }

    @Test func selectWithGroups() throws {
        let option = try expectRoundTrip(
            ACP.ConfigOption.self,
            [
                "id": "model", "name": "Model", "type": "select", "currentValue": "b",
                "options": [
                    ["group": "fast", "name": "Fast", "options": [["value": "a", "name": "A"]]],
                    ["group": "smart", "name": "Smart", "options": [["value": "b", "name": "B"]]],
                ],
            ]
        )
        guard case .select(_, let options) = option.value else {
            Issue.record("Expected select")
            return
        }
        #expect(options.allOptions.map(\.value) == ["a", "b"])
        if case .grouped(let groups) = options {
            #expect(groups.map(\.group) == ["fast", "smart"])
        } else {
            Issue.record("Expected groups")
        }
    }

    @Test func emptyOptionsAreFlat() throws {
        let options = try JSONValue.array([]).decode(as: ACP.ConfigSelectOptions.self)
        #expect(options == .flat([]))
        #expect(options.allOptions.isEmpty)
    }

    @Test func booleanAndUnknownTypes() throws {
        let boolean = try expectRoundTrip(
            ACP.ConfigOption.self,
            [
                "id": "web", "name": "Web", "description": "Search", "type": "boolean", "currentValue": true,
                "category": "x_custom",
            ]
        )
        #expect(boolean.value == .boolean(currentValue: true))
        #expect(boolean.category == .unknown("x_custom"))
        let slider: JSONValue = ["id": "temp", "name": "Temperature", "type": "slider", "min": 0]
        let unknown = try expectRoundTrip(ACP.ConfigOption.self, slider)
        #expect(unknown.value == .unknown(type: "slider", raw: slider))
    }

    @Test func invalidCategoryIsIgnored() throws {
        let option = try JSONValue.object([
            "id": "a", "name": "A", "type": "boolean", "currentValue": false, "category": 7,
        ])
        .decode(as: ACP.ConfigOption.self)
        #expect(option.category == nil)
    }

    @Test func setConfigOptionRequestEncodesValueTypes() throws {
        let select = try expectRoundTrip(
            ACP.V1.SetConfigOptionRequest.self,
            ["sessionId": "s", "configId": "model", "value": "b"]
        )
        #expect(select.value == .select("b"))
        let boolean = try expectRoundTrip(
            ACP.V1.SetConfigOptionRequest.self,
            ["sessionId": "s", "configId": "web", "type": "boolean", "value": false, "_meta": ["k": 1]]
        )
        #expect(boolean.value == .boolean(false))
    }
}

@Suite struct ElicitationTests {
    @Test func formRequest() throws {
        let json: JSONValue = [
            "sessionId": "s", "toolCallId": "t", "message": "Configure", "mode": "form",
            "requestedSchema": [
                "type": "object", "title": "Setup", "required": ["name"],
                "properties": [
                    "name": ["type": "string", "minLength": 1, "format": "email", "default": "a@b.c"],
                    "env": ["type": "string", "oneOf": [["const": "dev", "title": "Development"]]],
                    "region": ["type": "string", "enum": ["eu", "us"]],
                    "count": ["type": "integer", "minimum": 1, "maximum": 9, "default": 3],
                    "ratio": ["type": "number", "minimum": 0.5],
                    "enabled": ["type": "boolean", "default": true],
                    "tags": [
                        "type": "array", "minItems": 1, "items": ["type": "string", "enum": ["a", "b"]],
                        "default": ["a"],
                    ],
                    "picks": ["type": "array", "items": ["anyOf": [["const": "x", "title": "X"]]]],
                ],
            ],
        ]
        let request = try expectRoundTrip(ACP.ElicitationRequest.self, json)
        #expect(request.scope == .session("s", toolCallId: "t"))
        guard case .form(let schema) = request.mode else {
            Issue.record("Expected form")
            return
        }
        #expect(schema.properties.count == 8)
        #expect(schema.required == ["name"])
    }

    @Test func formSchemaDefaults() throws {
        let schema = try JSONValue.object([:]).decode(as: ACP.ElicitationSchema.self)
        #expect(schema.properties.isEmpty)
        #expect(try JSONValue(encoding: schema) == ["type": "object", "properties": [:]])
    }

    @Test func urlAndUnknownModes() throws {
        let url = try expectRoundTrip(
            ACP.ElicitationRequest.self,
            ["requestId": 4, "message": "Sign in", "mode": "url", "elicitationId": "e", "url": "https://x"]
        )
        #expect(url.mode == .url(elicitationId: "e", url: "https://x"))
        #expect(url.scope == .request(.int(4)))
        let unknown = try JSONValue.object(["sessionId": "s", "message": "m", "mode": "voice"]).decode(
            as: ACP.ElicitationRequest.self
        )
        #expect(unknown.mode == .unknown("voice"))
        #expect(try JSONValue(encoding: unknown) == ["sessionId": "s", "message": "m", "mode": "voice"])
    }

    @Test func responses() throws {
        let accept = try expectRoundTrip(
            ACP.ElicitationResponse.self,
            ["action": "accept", "content": ["name": "x", "count": 2]]
        )
        #expect(accept.action == .accept(["name": "x", "count": 2]))
        #expect(try expectRoundTrip(ACP.ElicitationResponse.self, ["action": "decline"]).action == .decline)
        #expect(
            try expectRoundTrip(ACP.ElicitationResponse.self, ["action": "cancel", "_meta": ["k": 1]]).action == .cancel
        )
        #expect(try expectRoundTrip(ACP.ElicitationResponse.self, ["action": "snooze"]).action == .unknown("snooze"))
        try expectRoundTrip(ACP.ElicitationComplete.self, ["elicitationId": "e"])
    }
}
