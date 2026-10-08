import ACP
import ACPTesting
import AgentRuntime
import Foundation
import JSONRPC
import Observation
import Persistence
import Synchronization
import Testing

@testable import AgenthesiaCore

private final class Fixture: Sendable {
    let directory: URL
    let store: PersistenceStore
    let project = ProjectRecord(name: "Test", rootPath: "/tmp/session-test")
    let agent = AgentInstallRecord(name: "Mock", executable: "MockAgent")

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "session-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try PersistenceStore(databaseURL: directory.appending(path: "history.sqlite"))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func seed() async throws -> SessionRecord {
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        return SessionRecord(projectID: project.id, agentInstallID: agent.id, workingDirectory: project.rootPath)
    }

    @MainActor func live() async throws -> SessionController {
        let controller = SessionController(session: try await seed(), store: store)
        let (server, client) = InMemoryTransport.pair()
        Task { await EchoAgent().serve(server) }
        let connection = await ACP.V1.AgentConnectionAdapter(transport: client, delegate: controller)
        try await controller.start(connection: connection, client: .init(name: "test", version: "1"))
        return controller
    }
}

private func rawUpdate(_ update: ACP.SessionUpdate, session: String = "s") throws -> Data {
    try JSONEncoder().encode(
        Message.notification(
            method: "session/update",
            params: try JSONValue(encoding: ACP.V1.SessionNotification(sessionId: session, update: update))
        )
    )
}

@Suite(.timeLimit(.minutes(1))) struct TranscriptTests {
    @Test func replayMessagesToolsAndMetadata() async throws {
        let fixture = try Fixture()
        let session = try await fixture.seed()
        try await fixture.store.createSession(session)
        let turn = UUID()
        let updates: [ACP.SessionUpdate] = [
            .agentThoughtChunk(.init(content: .init(text: "Thinking"))),
            .agentMessageChunk(.init(content: .init(text: "Hello "))),
            .agentMessageChunk(.init(content: .init(text: "world"))),
            .toolCall(.init(toolCallId: "t", title: "Read", kind: .read, status: .pending)),
            .toolCallUpdate(.init(toolCallId: "t", status: .completed, content: [])),
            .toolCallUpdate(.init(toolCallId: "orphan", status: .failed)),
            .sessionInfo(.init(title: "Title")),
            .sessionInfo(.init()),
            .usage(.init(used: 10, size: 100)),
            .unknown(["sessionUpdate": "future"]),
        ]
        var events = [try SessionEvent.prompt(id: turn, content: [.init(text: "Hi")]).storedEvent()]
        events += try updates.map { NewEvent(kind: SessionEvent.updateKind, payload: try rawUpdate($0)) }
        events.append(try SessionEvent.finished(id: turn, reason: .endTurn).storedEvent())
        events.append(NewEvent(kind: "future", formatVersion: 4, payload: Data("{}".utf8)))
        let stored = try await fixture.store.append(events, to: session.id)
        var state = TranscriptState()
        for event in stored { try state.apply(event) }
        #expect(state.items.compactMap { $0.message?.text } == ["Hi", "Thinking", "Hello world"])
        #expect(state.items.compactMap(\.toolCall).map(\.status) == [.completed, .failed])
        #expect(state.items.compactMap(\.toolCall).first?.title == "Read")
        #expect(state.title == "Title")
        #expect(state.usage?.used == 10)
        #expect(state.lastStopReason == .endTurn)
        #expect(state.activeTurn == nil)
        #expect(state.unsupportedEvents == 2)
        #expect(throws: TranscriptState.ReplayError.self) { try state.apply(stored[0]) }
    }

    @Test func chunkBoundariesRespectRolesMessageIDsAndAttachments() async throws {
        let fixture = try Fixture()
        let session = try await fixture.seed()
        try await fixture.store.createSession(session)
        let updates: [ACP.SessionUpdate] = [
            .agentMessageChunk(.init(content: .init(text: "A"), messageId: "a")),
            .agentMessageChunk(.init(content: .init(text: "B"), messageId: "b")),
            .agentMessageChunk(.init(content: .init(text: "C"), messageId: "a")),
            .agentMessageChunk(.init(content: .image(.init(data: "AA==", mimeType: "image/png")), messageId: "a")),
            .userMessageChunk(.init(content: .init(text: "User "))),
            .userMessageChunk(.init(content: .init(text: "chunk"))),
            .agentThoughtChunk(.init(content: .init(text: "Thought"))),
        ]
        let events = try await fixture.store.append(
            try updates.map { NewEvent(kind: SessionEvent.updateKind, payload: try rawUpdate($0)) },
            to: session.id
        )
        var state = TranscriptState()
        for event in events { try state.apply(event) }
        #expect(state.items.compactMap { $0.message?.text } == ["AC", "B", "User chunk", "Thought"])
        #expect(state.items[0].message?.content.count == 2)
        #expect(state.items.map(\.id) == [1, 2, 5, 7])
    }
}

/// A suspended append makes interleavings deterministic without timing sleeps.
private actor Gate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() { release?.resume(); release = nil }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionControllerTests {
    @Test func liveAndReplayMatchAfterEchoAndFailure() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        #expect(controller.status == .idle)
        try await controller.send([.init(text: "hello")])
        #expect(controller.transcript.items.compactMap { $0.message?.text } == ["hello", "Echo: hello"])
        #expect(controller.transcript.lastStopReason == .endTurn)
        await #expect(throws: (any Error).self) { try await controller.send([.init(text: "fail")]) }
        #expect(controller.status == .failed)
        #expect(controller.transcript.items.last?.notice != nil)
        let replay = try await SessionController.restore(id: controller.session.id, store: fixture.store)
        #expect(replay.status == .readOnly)
        #expect(replay.transcript == controller.transcript)
        await #expect(throws: SessionController.SessionError.invalidState) {
            try await replay.send([.init(text: "no")])
        }
        await controller.close()
    }

    @Test func recordsBytesExactlyAndPublishesOnlyAtFrameBoundary() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let id = try #require(controller.session.agentSessionID)
        let raw = Data(
            """
            { "jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"\(id)",
              "update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi"},
              "future":9007199254740993.123456789},"vendor":true},"extra":"untouched" }
            """.utf8
        )
        let changed = Mutex(0)
        withObservationTracking {
            _ = controller.transcript
        } onChange: {
            changed.withLock { $0 += 1 }
        }
        for _ in 0..<3 {
            await controller.sessionUpdate(
                .agentMessageChunk(.init(content: .init(text: "Hi"))),
                in: id,
                rawNotification: raw
            )
        }
        #expect(controller.transcript.items.isEmpty)
        #expect(changed.withLock { $0 } == 0)
        controller.publishTranscript()
        #expect(changed.withLock { $0 } == 1)
        #expect(controller.transcript.items.first?.message?.text == "HiHiHi")
        let events = try await fixture.store.events(in: controller.session.id)
        #expect(events.dropFirst().allSatisfy { $0.event.payload == raw })
        let replay = try await SessionController.restore(id: controller.session.id, store: fixture.store)
        #expect(replay.transcript == controller.transcript)
        await controller.close()
    }

    @Test func stopWhilePromptIsBeingCommittedNeverSendsIt() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let gate = Gate()
        let store = fixture.store
        controller.appendEvents = { events, id in
            if events.contains(where: {
                guard let local = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .prompt = local { return true }; return false
            }) {
                await gate.suspend()
            }
            return try await store.append(events, to: id)
        }
        let send = Task { try await controller.send([.init(text: "never sent")]) }
        await gate.waitUntilEntered()
        await #expect(throws: SessionController.SessionError.invalidState) {
            try await controller.send([.init(text: "busy")])
        }
        let stop = Task { try await controller.stop() }
        // Let stop enter the controller before releasing the prompt write.
        while controller.status != .stopping { await Task.yield() }
        await gate.open()
        try await stop.value
        try await send.value
        #expect(controller.status == .idle)
        #expect(controller.transcript.lastStopReason == .cancelled)
        #expect(controller.transcript.items.count == 1)
        let events = try await store.events(in: controller.session.id)
        #expect(events.map(\.sequence) == [1, 2, 3, 4])
        let replay = try await SessionController.restore(id: controller.session.id, store: store)
        #expect(replay.transcript == controller.transcript)
        await controller.close()
    }

    @Test func diskFailureStopsSessionWithoutPublishingUncommittedText() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let before = controller.transcript
        controller.appendEvents = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        await #expect(throws: (any Error).self) { try await controller.send([.init(text: "not saved")]) }
        #expect(controller.status == .failed)
        #expect(controller.errorMessage != nil)
        #expect(controller.transcript == before)
        #expect(try await fixture.store.events(in: controller.session.id).count == 1)
        await controller.close()
    }

    @Test func missingRawDataFailsInsteadOfReencoding() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        await controller.sessionUpdate(
            .agentMessageChunk(.init(content: .init(text: "lost fields"))),
            in: try #require(controller.session.agentSessionID)
        )
        #expect(controller.status == .failed)
        #expect(controller.transcript.items.isEmpty)
        await controller.close()
    }

    @Test func restoresMoreThanOnePageAndShowsUnfinishedTurn() async throws {
        let fixture = try Fixture()
        let session = try await fixture.seed()
        try await fixture.store.createSession(session)
        let id = UUID()
        let events =
            [try SessionEvent.prompt(id: id, content: [.init(text: "hello")]).storedEvent()]
            + (0..<1001).map { _ in NewEvent(kind: "future", payload: Data("{}".utf8)) }
        _ = try await fixture.store.append(events, to: session.id)
        let restored = try await SessionController.restore(id: session.id, store: fixture.store)
        #expect(restored.transcript.sequence == 1002)
        #expect(restored.transcript.activeTurn == id)
        #expect(restored.status == .readOnly)
        await #expect(throws: SessionController.SessionError.sessionNotFound) {
            try await SessionController.restore(id: UUID(), store: fixture.store)
        }
    }
}

extension SessionControllerTests {
    @Test func cancellationKeepsLateChunksAndForcesFinalPublication() async throws {
        let fixture = try Fixture()
        let controller = SessionController(session: try await fixture.seed(), store: fixture.store)
        let (server, client) = InMemoryTransport.pair()
        let update: @Sendable (String) -> JSONValue = { text in
            [
                "sessionId": "s",
                "update": [
                    "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(text)],
                ],
            ]
        }
        let agent = ScenarioAgent(
            scenario: Scenario([
                .expectRequest(method: "initialize", response: .result(["protocolVersion": 1])),
                .expectRequest(method: "session/new", response: .result(["sessionId": "s"])),
                .expectRequest(method: "session/prompt", response: nil, deferAs: "turn"),
                .sendNotification(method: "session/update", params: update("before")),
                .expectNotification(method: "session/cancel"),
                .sendNotification(method: "session/update", params: update("after")),
                .respond(to: "turn", response: .result(["stopReason": "cancelled"])),
            ]),
            transport: server
        )
        let agentRun = Task { await agent.run() }
        let connection = await ACP.V1.AgentConnectionAdapter(transport: client, delegate: controller)
        try await controller.start(connection: connection, client: .init(name: "test", version: "1"))
        let (notifications, received) = AsyncStream<Void>.makeStream()
        let store = fixture.store
        controller.appendEvents = { events, id in
            let stored = try await store.append(events, to: id)
            if events.contains(where: { $0.kind == SessionEvent.updateKind }) { received.yield(()) }
            return stored
        }
        let turn = Task { try await controller.send([.init(text: "go")]) }
        var iterator = notifications.makeAsyncIterator()
        _ = await iterator.next()
        try await controller.stop()
        try await turn.value
        #expect(await agentRun.value == nil)
        #expect(controller.status == .idle)
        #expect(controller.transcript.items.last?.message?.text == "beforeafter")
        #expect(controller.transcript.lastStopReason == .cancelled)
        let replay = try await SessionController.restore(id: controller.session.id, store: store)
        #expect(replay.transcript == controller.transcript)
        await controller.close()
    }

    @Test func permissionsAreRecordedAndNeverImplicitlyGranted() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        try await controller.send([.init(text: "write /tmp/unwritten.txt content")])
        #expect(controller.transcript.items.contains { $0.permission == .selected("reject") })
        #expect(controller.transcript.lastStopReason == .endTurn)
        #expect(controller.status == .idle)
        let replay = try await SessionController.restore(id: controller.session.id, store: fixture.store)
        #expect(replay.transcript == controller.transcript)
        await controller.close()
    }

    @Test func failingStreamWriteDoesNotPublishFailedChunk() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let store = fixture.store
        controller.appendEvents = { events, id in
            if events.contains(where: { $0.kind == SessionEvent.updateKind }) { throw CocoaError(.fileWriteOutOfSpace) }
            return try await store.append(events, to: id)
        }
        await #expect(throws: (any Error).self) { try await controller.send([.init(text: "hello")]) }
        #expect(controller.status == .failed)
        #expect(controller.transcript.items.compactMap { $0.message?.text } == ["hello"])
        #expect(controller.transcript.activeTurn != nil)
        let replay = try await SessionController.restore(id: controller.session.id, store: store)
        #expect(replay.transcript == controller.transcript)
        await controller.close()
    }

    @Test func startupNotificationsAndNormalizedSettingsSurviveReplay() async throws {
        let fixture = try Fixture()
        let controller = SessionController(session: try await fixture.seed(), store: fixture.store)
        let (server, client) = InMemoryTransport.pair()
        let scenario = Scenario([
            .expectRequest(method: "initialize", response: .result(["protocolVersion": 1])),
            .expectRequest(method: "session/new", response: nil, deferAs: "new"),
            .sendNotification(
                method: "session/update",
                params: [
                    "sessionId": "s", "update": ["sessionUpdate": "session_info_update", "title": "Early title"],
                ]
            ),
            .respond(
                to: "new",
                response: .result([
                    "sessionId": "s",
                    "modes": [
                        "currentModeId": "ask",
                        "availableModes": [
                            ["id": "ask", "name": "Ask"], ["id": "code", "name": "Code"],
                        ],
                    ],
                ])
            ),
            .expectRequest(method: "session/prompt", response: nil, deferAs: "turn"),
            .sendNotification(
                method: "session/update",
                params: [
                    "sessionId": "s", "update": ["sessionUpdate": "current_mode_update", "currentModeId": "code"],
                ]
            ),
            .respond(to: "turn", response: .result(["stopReason": "end_turn"])),
        ])
        let agent = ScenarioAgent(scenario: scenario, transport: server)
        let run = Task { await agent.run() }
        let connection = await ACP.V1.AgentConnectionAdapter(transport: client, delegate: controller)
        try await controller.start(connection: connection, client: .init(name: "test", version: "1"))
        #expect(controller.transcript.title == "Early title")
        try await controller.send([.init(text: "go")])
        #expect(await run.value == nil)
        #expect(controller.transcript.currentModeID == "code")
        guard case .select(let mode, _) = controller.transcript.configOptions.first?.value else {
            Issue.record("Expected mode option"); return
        }
        #expect(mode == "code")
        let replay = try await SessionController.restore(id: controller.session.id, store: fixture.store)
        #expect(replay.transcript == controller.transcript)
        await controller.close()
    }

    @Test func realMockAgentProcessRoundTrip() async throws {
        let fixture = try Fixture()
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let candidates = [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"].map {
            package.appending(path: $0)
        }
        let binary = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path()) })
        var environment = ProcessInfo.processInfo.environment
        if environment["LLVM_PROFILE_FILE"] == nil {
            environment["LLVM_PROFILE_FILE"] = fixture.directory.appending(path: "mock-%p.profraw").path()
        }
        let process = try AgentProcess(launching: .init(executable: binary.path(), environment: environment))
        let controller = SessionController(session: try await fixture.seed(), store: fixture.store)
        let connection = await ACP.V1.AgentConnectionAdapter(transport: process.transport, delegate: controller)
        do {
            try await controller.start(connection: connection, client: .init(name: "test", version: "1"))
            try await controller.send([.init(text: "hello process")])
            #expect(controller.transcript.items.last?.message?.text == "Echo: hello process")
            let replay = try await SessionController.restore(id: controller.session.id, store: fixture.store)
            #expect(replay.transcript == controller.transcript)
        } catch {
            await controller.close()
            _ = await process.terminate()
            throw error
        }
        await controller.close()
        #expect(await process.waitForExit() == .exited(0))
    }
}

extension SessionControllerTests {
    @Test func cancellingAWaitingUITaskDoesNotCancelItsOwnedTurn() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let gate = Gate()
        let store = fixture.store
        controller.appendEvents = { events, id in
            if events.contains(where: {
                guard let local = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .prompt = local { return true }; return false
            }) {
                await gate.suspend()
            }
            return try await store.append(events, to: id)
        }
        let waiter = Task { try await controller.send([.init(text: "still running")]) }
        await gate.waitUntilEntered()
        waiter.cancel()
        await gate.open()
        try await waiter.value
        #expect(controller.status == .idle)
        #expect(controller.transcript.items.last?.message?.text == "Echo: still running")
        await controller.close()
    }

    @Test func closeWaitsForAPromptWriteAndKeepsReplayConsistent() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let gate = Gate()
        let store = fixture.store
        controller.appendEvents = { events, id in
            if events.contains(where: {
                guard let local = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .prompt = local { return true }; return false
            }) {
                await gate.suspend()
            }
            return try await store.append(events, to: id)
        }
        let send = Task { try await controller.send([.init(text: "closing")]) }
        await gate.waitUntilEntered()
        let closing = Task { await controller.close() }
        while controller.status != .closed { await Task.yield() }
        await gate.open()
        await closing.value
        await #expect(throws: (any Error).self) { try await send.value }
        #expect(controller.status == .closed)
        let replay = try await SessionController.restore(id: controller.session.id, store: store)
        #expect(replay.transcript == controller.transcript)
        #expect(replay.transcript.activeTurn == nil)
    }
}

extension SessionControllerTests {
    @Test func undecodableUpdateIsPersistedAndReplayContinues() async throws {
        let fixture = try Fixture()
        let controller = SessionController(session: try await fixture.seed(), store: fixture.store)
        let (server, client) = InMemoryTransport.pair()
        let raw = Data(
            """
            { "jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s", "update":{
            "sessionUpdate":"agent_message_chunk", "content":{"type":"text","text":123},
            "future":9007199254740993.123456789}} }
            """.utf8
        )
        var router = Router()
        router.on(ACP.V1.Method.Initialize.self) { _ in .init(protocolVersion: 1) }
        router.on(ACP.V1.Method.NewSession.self) { _ in .init(sessionId: "s") }
        router.on(ACP.V1.Method.Prompt.self) { _ in
            try await server.send(raw)
            try await server.send(rawUpdate(.agentMessageChunk(.init(content: .init(text: "Still here")))))
            return .init(stopReason: .endTurn)
        }
        let peer = Connection(transport: server)
        await peer.start(handler: router)
        let connection = await ACP.V1.AgentConnectionAdapter(transport: client, delegate: controller)
        try await controller.start(connection: connection, client: .init(name: "test", version: "1"))
        try await controller.send([.init(text: "go")])
        #expect(controller.status == .idle)
        #expect(controller.transcript.unsupportedEvents == 1)
        #expect(controller.transcript.items.last?.message?.text == "Still here")
        let events = try await fixture.store.events(in: controller.session.id)
        #expect(events[2].event.payload == raw)
        let replay = try await SessionController.restore(id: controller.session.id, store: fixture.store)
        #expect(replay.transcript == controller.transcript)
        await controller.close()
    }

    @Test func closingARunningTurnRecordsCancellation() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let (updates, received) = AsyncStream<Void>.makeStream()
        let store = fixture.store
        controller.appendEvents = { events, id in
            let stored = try await store.append(events, to: id)
            if events.contains(where: { $0.kind == SessionEvent.updateKind }) { received.yield(()) }
            return stored
        }
        let turn = Task { try await controller.send([.init(text: "slow")]) }
        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()
        await controller.close()
        await #expect(throws: CancellationError.self) { try await turn.value }
        let replay = try await SessionController.restore(id: controller.session.id, store: store)
        #expect(replay.transcript.lastStopReason == .cancelled)
        #expect(replay.transcript.activeTurn == nil)
        #expect(!replay.transcript.items.contains { $0.notice != nil })
        #expect(controller.errorMessage == nil)
    }

    @Test func closeDuringInitializationCancelsStartup() async throws {
        let fixture = try Fixture()
        let controller = SessionController(session: try await fixture.seed(), store: fixture.store)
        let (server, client) = InMemoryTransport.pair()
        let gate = Gate()
        var router = Router()
        router.on(ACP.V1.Method.Initialize.self) { _ in
            await gate.suspend()
            return .init(protocolVersion: 1)
        }
        let peer = Connection(transport: server)
        await peer.start(handler: router)
        let connection = await ACP.V1.AgentConnectionAdapter(transport: client, delegate: controller)
        let start = Task {
            try await controller.start(connection: connection, client: .init(name: "test", version: "1"))
        }
        await gate.waitUntilEntered()
        await controller.close()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(controller.status == .closed)
        #expect(controller.errorMessage == nil)
        await peer.close()
    }

    @Test(arguments: [false, true]) func sessionCreationFailureSurvivesClose(closing: Bool) async throws {
        let fixture = try Fixture()
        let controller = SessionController(session: try await fixture.seed(), store: fixture.store)
        let gate = Gate()
        let diskError = CocoaError(.fileWriteOutOfSpace)
        controller.createSession = { _ in
            await gate.suspend()
            throw diskError
        }
        controller.appendEvents = { _, _ in
            Issue.record("Startup events must not be written after session creation fails")
            return []
        }
        let (server, client) = InMemoryTransport.pair()
        Task { await EchoAgent().serve(server) }
        let connection = await ACP.V1.AgentConnectionAdapter(transport: client, delegate: controller)
        let start = Task {
            try await controller.start(connection: connection, client: .init(name: "test", version: "1"))
        }
        await gate.waitUntilEntered()
        if closing { await controller.close() }
        await gate.open()
        do {
            try await start.value
            Issue.record("Expected the session creation error")
        } catch {
            #expect((error as? CocoaError)?.code == .fileWriteOutOfSpace)
            #expect(controller.errorMessage == String(describing: error))
        }
        #expect(controller.status == (closing ? .closed : .failed))
        #expect(controller.transcript.sequence == 0)
        #expect(try await fixture.store.session(id: controller.session.id) == nil)
        await controller.close()
    }

    @Test(arguments: [false, true]) func closeDuringStartupWritePreservesDiskFailure(failing: Bool) async throws {
        let fixture = try Fixture()
        let controller = SessionController(session: try await fixture.seed(), store: fixture.store)
        let store = fixture.store
        let gate = Gate()
        controller.appendEvents = { events, id in
            await gate.suspend()
            if failing { throw CocoaError(.fileWriteOutOfSpace) }
            return try await store.append(events, to: id)
        }
        let (server, client) = InMemoryTransport.pair()
        Task { await EchoAgent().serve(server) }
        let connection = await ACP.V1.AgentConnectionAdapter(transport: client, delegate: controller)
        let start = Task {
            try await controller.start(connection: connection, client: .init(name: "test", version: "1"))
        }
        await gate.waitUntilEntered()
        let closing = Task { await controller.close() }
        while controller.status != .closed { await Task.yield() }
        await gate.open()
        await closing.value
        do {
            try await start.value
            Issue.record("Expected startup to throw after close")
        } catch {
            if failing {
                #expect((error as? CocoaError)?.code == .fileWriteOutOfSpace)
            } else {
                #expect(error is CancellationError)
            }
        }
        #expect(controller.status == .closed)
        #expect((controller.errorMessage != nil) == failing)
    }

    @Test func startupRethrowsTheFirstFailure() async throws {
        let fixture = try Fixture()
        let controller = SessionController(session: try await fixture.seed(), store: fixture.store)
        let (server, client) = InMemoryTransport.pair()
        let entered = Gate()
        var router = Router()
        router.on(ACP.V1.Method.Initialize.self) { _ in
            await entered.suspend()
            return .init(protocolVersion: 1)
        }
        let peer = Connection(transport: server)
        await peer.start(handler: router)
        let connection = await ACP.V1.AgentConnectionAdapter(transport: client, delegate: controller)
        let start = Task {
            try await controller.start(connection: connection, client: .init(name: "test", version: "1"))
        }
        await entered.waitUntilEntered()
        await controller.sessionUpdate(.agentMessageChunk(.init(content: .init(text: "missing raw"))), in: "s")
        await entered.open()
        await #expect(throws: SessionController.SessionError.missingRawNotification) { try await start.value }
        #expect(controller.status == .failed)
        await controller.close()
    }

    @Test func streamWriteRethrowsDiskErrorRatherThanConnectionClosed() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let store = fixture.store
        controller.appendEvents = { events, id in
            if events.contains(where: { $0.kind == SessionEvent.updateKind }) { throw CocoaError(.fileWriteOutOfSpace) }
            return try await store.append(events, to: id)
        }
        do {
            try await controller.send([.init(text: "hello")])
            Issue.record("Expected a disk error")
        } catch {
            #expect((error as? CocoaError)?.code == .fileWriteOutOfSpace)
        }
        await controller.close()
    }

    @Test(arguments: [false, true]) func permissionCancellationAndMissingRejectOption(stopping: Bool) async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let gate = Gate()
        let store = fixture.store
        controller.appendEvents = { events, id in
            if events.contains(where: {
                guard let event = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .prompt = event { return true }; return false
            }) {
                await gate.suspend()
            }
            return try await store.append(events, to: id)
        }
        let turn = Task { try await controller.send([.init(text: "hello")]) }
        await gate.waitUntilEntered()
        let stop = stopping ? Task { try await controller.stop() } : nil
        if stopping { while controller.status != .stopping { await Task.yield() } }
        let permission = Task {
            await controller.requestPermission(
                for: .init(toolCallId: "t"),
                options: stopping ? [.init(optionId: "reject", name: "Reject", kind: .rejectOnce)] : [],
                in: try #require(controller.session.agentSessionID)
            )
        }
        await gate.open()
        #expect(try await permission.value == .cancelled)
        try await stop?.value
        try await turn.value
        await controller.close()
    }
}

extension SessionControllerTests {
    @Test func stopDuringPermissionWriteReturnsAndRecordsCancellation() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let (updates, received) = AsyncStream<Void>.makeStream()
        let gate = Gate()
        let gated = Mutex(false)
        let store = fixture.store
        controller.appendEvents = { events, id in
            let isPermission = events.contains {
                guard let event = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .permission = event { return true }; return false
            }
            if isPermission,
                gated.withLock({ value in
                    if value { return false }; value = true; return true
                })
            {
                await gate.suspend()
            }
            let stored = try await store.append(events, to: id)
            if events.contains(where: { $0.kind == SessionEvent.updateKind }) { received.yield(()) }
            return stored
        }
        let turn = Task { try await controller.send([.init(text: "slow")]) }
        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()
        let permission = Task {
            await controller.requestPermission(
                for: .init(toolCallId: "blocked"),
                options: [.init(optionId: "reject", name: "Reject", kind: .rejectOnce)],
                in: try #require(controller.session.agentSessionID)
            )
        }
        await gate.waitUntilEntered()
        let stop = Task { try await controller.stop() }
        while controller.status != .stopping { await Task.yield() }
        await gate.open()
        #expect(try await permission.value == .cancelled)
        try await stop.value
        try await turn.value
        let replay = try await SessionController.restore(id: controller.session.id, store: store)
        #expect(replay.transcript.items.first { $0.toolCall?.toolCallId == "blocked" }?.permission == .cancelled)
        #expect(replay.transcript == controller.transcript)
        await controller.close()
    }

    @Test(arguments: [false, true])
    func diskFailureRacingWithCloseIsNotReportedAsCancellation(failOnFinish: Bool) async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let gate = Gate()
        let store = fixture.store
        controller.appendEvents = { events, id in
            let local = try JSONDecoder().decode(SessionEvent.self, from: events[0].payload)
            if case .prompt = local { await gate.suspend() }
            if !failOnFinish { throw CocoaError(.fileWriteOutOfSpace) }
            if case .finished = local { throw CocoaError(.fileWriteOutOfSpace) }
            return try await store.append(events, to: id)
        }
        let turn = Task { try await controller.send([.init(text: "hello")]) }
        await gate.waitUntilEntered()
        let closing = Task { await controller.close() }
        while controller.status != .closed { await Task.yield() }
        await gate.open()
        await closing.value
        do {
            try await turn.value
            Issue.record("Expected disk error")
        } catch {
            #expect((error as? CocoaError)?.code == .fileWriteOutOfSpace)
        }
        #expect(controller.errorMessage != nil)
    }
}
