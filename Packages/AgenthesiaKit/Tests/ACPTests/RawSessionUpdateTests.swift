import ACP
import Foundation
import JSONRPC
import Synchronization
import Testing

private final class RawDelegate: ACP.AgentConnectionDelegate {
    let updates = Mutex<[(ACP.SessionUpdate, Data)]>([])
    func sessionUpdate(_ update: ACP.SessionUpdate, in sessionId: ACP.SessionID) async {
        Issue.record("Original notification was not forwarded")
    }
    func sessionUpdate(_ update: ACP.SessionUpdate, in sessionId: ACP.SessionID, rawNotification: Data) async {
        updates.withLock { $0.append((update, rawNotification)) }
    }
    func requestPermission(
        for toolCall: ACP.ToolCallUpdate,
        options: [ACP.PermissionOption],
        in sessionId: ACP.SessionID
    ) async -> ACP.PermissionOutcome { .cancelled }
}

@Suite(.timeLimit(.minutes(1))) struct RawSessionUpdateTests {
    @Test func preservesOriginalBytesAlongsideNormalizedUpdates() async throws {
        let (server, client) = InMemoryTransport.pair()
        let raw = Data(
            """
            { "jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s", "update":{
            "sessionUpdate":"current_mode_update","currentModeId":"code","future":9007199254740993.123456789}},
            "vendor_extension":true }
            """.utf8
        )
        var router = Router()
        router.on(ACP.V1.Method.Initialize.self) { _ in .init(protocolVersion: 1) }
        router.on(ACP.V1.Method.NewSession.self) { _ in
            .init(
                sessionId: "s",
                modes: .init(
                    currentModeId: "ask",
                    availableModes: [
                        .init(id: "ask", name: "Ask"), .init(id: "code", name: "Code"),
                    ]
                )
            )
        }
        router.on(ACP.V1.Method.Prompt.self) { _ in
            // No session id: log the invalid envelope, then continue processing the stream.
            try await server.send(Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"update":{}}}"#.utf8))
            try await server.send(raw)
            return .init(stopReason: .endTurn)
        }
        let serverConnection = Connection(transport: server)
        await serverConnection.start(handler: router)
        let delegate = RawDelegate()
        let connection = await ACP.V1.AgentConnectionAdapter(transport: client, delegate: delegate)
        _ = try await connection.initialize(client: .init(name: "test", version: "1"))
        _ = try await connection.newSession(cwd: "/tmp", additionalDirectories: [], mcpServers: [])
        _ = try await connection.prompt([.init(text: "test")], in: "s")
        let updates = delegate.updates.withLock { $0 }
        #expect(updates.count == 1)
        #expect(updates.first?.1 == raw)
        guard case .configOptions(let options) = try #require(updates.first?.0) else {
            Issue.record("Expected normalized config options"); return
        }
        #expect(options.configOptions.first?.category == .mode)
        let decoded = try ACP.RecordedSessionUpdate(rawNotification: raw)
        #expect(decoded.sessionId == "s")
        guard case .currentMode(let mode) = decoded.update else { Issue.record("Lost raw mode"); return }
        #expect(mode.currentModeId == "code")
        await connection.close()
    }

    @Test func rejectsNonUpdateEnvelope() {
        #expect(throws: DecodingError.self) {
            try ACP.RecordedSessionUpdate(
                rawNotification: Data(
                    #"{"jsonrpc":"1.0","method":"other","params":{"sessionId":"s","update":{"sessionUpdate":"future"}}}"#
                        .utf8
                )
            )
        }
    }
}

extension RawSessionUpdateTests {
    @Test func recordingToleratesBadTypedPayloadButWireModelRemainsStrict() throws {
        let raw = Data(
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":"future","size":10},"_meta":{"vendor":true}}}"#
                .utf8
        )
        let recorded = try ACP.RecordedSessionUpdate(rawNotification: raw)
        guard case .unknown = recorded.update else { Issue.record("Expected opaque update"); return }
        #expect(recorded.meta?["vendor"] == .bool(true))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ACP.SessionUpdate.self,
                from: Data(#"{"sessionUpdate":"usage_update","used":"future","size":10}"#.utf8)
            )
        }
    }
}
