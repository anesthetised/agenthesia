import ACP
import Foundation
import JSONRPC
import Persistence
import Testing

@testable import AgenthesiaCore

private actor QueueConnection: ACP.AgentConnection {
    var prompts: [[ACP.ContentBlock]] = []
    var injections: [[ACP.ContentBlock]] = []
    var cancellationCount = 0
    var waiter: CheckedContinuation<ACP.StopReason, any Error>?
    var rejectsInjection = false
    var cancelGate: QueueGate?
    let strategy: ACP.SteeringStrategy
    init(strategy: ACP.SteeringStrategy = .interruptAndSend) { self.strategy = strategy }
    func initialize(client: ACP.Implementation) async throws -> ACP.AgentProfile {
        .init(protocolVersion: 1, steering: strategy)
    }
    func authenticate(methodId: ACP.AuthMethodID) async throws {}
    func logout() async throws {}
    func newSession(
        cwd: String,
        additionalDirectories: [String],
        mcpServers: [ACP.MCPServer]
    ) async throws -> ACP.SessionState {
        .init(sessionId: "queue", configOptions: [])
    }
    func reopenSession(
        _ sessionId: ACP.SessionID,
        cwd: String,
        additionalDirectories: [String],
        mcpServers: [ACP.MCPServer]
    ) async throws -> ACP.ReopenedSession {
        .resumed(.init(sessionId: sessionId, configOptions: []))
    }
    func listSessions(cwd: String?) async throws -> [ACP.SessionInfo] { [] }
    func closeSession(_ sessionId: ACP.SessionID) async throws {}
    func deleteSession(_ sessionId: ACP.SessionID) async throws {}
    func prompt(_ content: [ACP.ContentBlock], in sessionId: ACP.SessionID) async throws -> ACP.StopReason {
        prompts.append(content)
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func inject(_ content: [ACP.ContentBlock], in sessionId: ACP.SessionID) async throws {
        if rejectsInjection { throw ACP.SteeringError.injectionUnsupported }
        injections.append(content)
    }
    func rejectInjection() { rejectsInjection = true }
    func cancel(_ sessionId: ACP.SessionID) async throws {
        cancellationCount += 1
        await cancelGate?.suspend()
        finish(.cancelled)
    }
    func suspendCancellation(on gate: QueueGate) { cancelGate = gate }
    func setConfigOption(
        _ configId: ACP.ConfigOptionID,
        to value: ACP.ConfigValue,
        in sessionId: ACP.SessionID
    ) async throws -> [ACP.ConfigOption] { [] }
    func close() async { waiter?.resume(throwing: CancellationError()); waiter = nil }
    func finish(_ reason: ACP.StopReason) { waiter?.resume(returning: reason); waiter = nil }
    func breakTurn() { waiter?.resume(throwing: QueueFailure()); waiter = nil }
    func rejectTurn() { waiter?.resume(throwing: RPCError.internalError("Rejected prompt")); waiter = nil }
    func waitForPrompts(_ count: Int) async { while prompts.count < count { await Task.yield() } }
}

private struct QueueFailure: Error {}

private actor QueueGate {
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

@MainActor @Suite(.timeLimit(.minutes(1))) struct PromptQueueTests {
    private func live(
        strategy: ACP.SteeringStrategy = .interruptAndSend
    ) async throws -> (SessionController, QueueConnection, PersistenceStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "queue-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(databaseURL: directory.appending(path: "history.sqlite"))
        let project = ProjectRecord(name: "Queue", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Queue", executable: "mock")
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        let session = SessionController(
            session: .init(projectID: project.id, agentInstallID: agent.id, workingDirectory: directory.path),
            store: store
        )
        let connection = QueueConnection(strategy: strategy)
        try await session.start(connection: connection, client: .init(name: "test", version: "1"))
        return (session, connection, store, directory)
    }

    @Test func queueEditsOrderAndAttachmentsReplayAndDrainTogether() async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        let attachment = ACP.ContentBlock.resourceLink(.init(uri: "file:///tmp/a", name: "a"))
        try await session.submit([.init(text: "first"), attachment])
        try await session.submit([.init(text: "second")])
        let first = try #require(session.queuedPrompts.first)
        let second = try #require(session.queuedPrompts.last)
        try await session.updateQueuedPrompt(first.id, text: "edited")
        try await session.moveQueuedPrompt(second.id, to: 0)
        let restored = try await SessionController.restore(id: session.session.id, store: store)
        #expect(restored.queuedPrompts.map(\.id) == [second.id, first.id])
        #expect(restored.queuedPrompts.last?.content == [.init(text: "edited"), attachment])
        #expect(restored.queuePaused)
        await connection.finish(.endTurn)
        await connection.waitForPrompts(2)
        #expect(await connection.prompts.last == [.init(text: "second"), .init(text: "edited"), attachment])
        #expect(session.queuedPrompts.isEmpty)
        await #expect(throws: SessionController.SessionError.invalidState) {
            try await session.updateQueuedPrompt(first.id, text: "too late")
        }
        session.publishTranscript()
        let messages = session.transcript.items.compactMap(\.message)
        #expect(messages.suffix(2).map(\.localPromptID) == [second.id, first.id])
        #expect(messages.suffix(2).allSatisfy { $0.sentTogether })
        #expect(Set(session.transcript.items.map(\.id)).count == session.transcript.items.count)
        await session.close()
    }

    @Test func manualStopAndRefusalRequireExplicitResume() async throws {
        let (session, connection, _, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        try await session.submit([.init(text: "later")])
        try await session.stop()
        while session.status != .idle { await Task.yield() }
        #expect(session.queuePaused && session.queuedPrompts.count == 1)
        #expect(await connection.prompts.count == 1)
        try await session.resumeQueue()
        await connection.waitForPrompts(2)
        try await session.submit([.init(text: "after refusal")])
        await connection.finish(.refusal)
        while session.status != .idle { await Task.yield() }
        #expect(session.queuePaused && session.queuedPrompts.count == 1)
        await session.close()
    }

    @Test(arguments: [false, true]) func sendNowWithEmptyDraftSendsTheWholeQueue(working: Bool) async throws {
        let (session, connection, _, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        if working {
            try await session.submit([.init(text: "working")])
            await connection.waitForPrompts(1)
        } else {
            try await session.stop()
        }
        let attachment = ACP.ContentBlock.resourceLink(.init(uri: "file:///tmp/a", name: "a"))
        try await session.submit([.init(text: "first"), attachment])
        try await session.submit([.init(text: "second")])
        let queued = session.queuedPrompts
        try await session.submit([.init(text: " \n")], intent: .now)
        await connection.waitForPrompts(working ? 2 : 1)
        #expect(await connection.prompts.last == [.init(text: "first"), attachment, .init(text: "second")])
        #expect(session.queuedPrompts.isEmpty)
        #expect(session.transcript.items.compactMap(\.message).suffix(2).map(\.localPromptID) == queued.map(\.id))
        await session.close()
    }

    @Test func sendNowRequiresContentAndAttachmentOnlyDraftLeavesTheQueue() async throws {
        let (session, connection, _, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: SessionController.SessionError.emptyPrompt) {
            try await session.submit([], intent: .now)
        }
        #expect(await connection.prompts.isEmpty)
        try await session.stop()
        try await session.submit([.init(text: "queued")])
        let queued = session.queuedPrompts
        let attachment = ACP.ContentBlock.resourceLink(.init(uri: "file:///tmp/a", name: "a"))
        try await session.submit([attachment], intent: .now)
        await connection.waitForPrompts(1)
        #expect(await connection.prompts == [[attachment]])
        #expect(session.queuedPrompts == queued)
        await session.close()
    }

    @Test(arguments: [false, true]) func sendNowUsesTheAdvertisedStrategy(all: Bool) async throws {
        for strategy in [ACP.SteeringStrategy.interruptAndSend, .inject] {
            let (session, connection, _, directory) = try await live(strategy: strategy)
            defer { try? FileManager.default.removeItem(at: directory) }
            try await session.submit([.init(text: "start")])
            await connection.waitForPrompts(1)
            try await session.submit([.init(text: "queued")])
            try await session.submit([.init(text: "draft")], intent: all ? .allNow : .now)
            let expected: [ACP.ContentBlock] =
                all ? [.init(text: "queued"), .init(text: "draft")] : [.init(text: "draft")]
            if strategy == .inject {
                #expect(await connection.injections == [expected])
                #expect(await connection.cancellationCount == 0)
            } else {
                await connection.waitForPrompts(2)
                #expect(await connection.prompts.last == expected)
                #expect(await connection.cancellationCount == 1)
                #expect(session.transcript.items.contains { $0.notice == "Interrupted" })
            }
            #expect(session.queuedPrompts.count == (all ? 0 : 1))
            await session.close()
        }
    }

    @Test func fatalFailureKeepsQueueAndContinueRequiresResume() async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        try await session.submit([.init(text: "kept")])
        await connection.breakTurn()
        while session.status != .failed { await Task.yield() }
        #expect(session.queuePaused && session.queuedPrompts.count == 1)
        await #expect(throws: SessionController.SessionError.invalidState) { try await session.resumeQueue() }
        await session.close()
        let continued = try await SessionController.history(id: session.session.id, store: store)
        let newConnection = QueueConnection()
        try await continued.reopen(connection: newConnection, client: .init(name: "test", version: "1"))
        #expect(continued.queuePaused && continued.queuedPrompts.count == 1)
        #expect(await newConnection.prompts.isEmpty)
        try await continued.resumeQueue()
        await newConnection.waitForPrompts(1)
        await continued.close()
    }

    @Test func promptErrorKeepsAttachmentsAndAllowsExplicitSendAndResume() async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        let attachment = ACP.ContentBlock.resourceLink(.init(uri: "file:///tmp/a", name: "a"))
        try await session.submit([.init(text: "retained"), attachment])
        let queued = session.queuedPrompts
        await connection.rejectTurn()
        while session.status == .running { await Task.yield() }
        try #require(session.status == .idle)
        #expect(session.queuePaused && session.queuedPrompts == queued)
        #expect(session.completedTurns == 0 && session.transcript.activeTurn == nil)
        let restored = try await SessionController.restore(id: session.session.id, store: store)
        #expect(restored.transcript == session.transcript && restored.queuePaused)
        try await session.submit([.init(text: "new draft")])
        #expect(await connection.prompts.count == 1)
        try await session.submit([.init(text: "send now")], intent: .now)
        await connection.waitForPrompts(2)
        #expect(await connection.prompts.last == [.init(text: "send now")])
        await connection.finish(.endTurn)
        while session.status == .running { await Task.yield() }
        #expect(session.queuePaused && session.queuedPrompts.map(\.text) == ["retained", "new draft"])
        try await session.resumeQueue()
        await connection.waitForPrompts(3)
        #expect(await connection.prompts.last == [.init(text: "retained"), attachment, .init(text: "new draft")])
        await session.close()
    }

    @Test(arguments: [false, true]) func promptErrorWaitsForCancellationBeforeSteeringOrStop(
        steering: Bool
    ) async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        let gate = QueueGate()
        let errorWrite = QueueGate()
        session.appendEvents = { events, id in
            if events.contains(where: {
                guard let event = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .failed = event { return true }
                return false
            }) {
                await errorWrite.suspend()
            }
            return try await store.append(events, to: id)
        }
        await connection.suspendCancellation(on: gate)
        let operation = Task {
            if steering {
                try await session.submit([.init(text: "replacement")], intent: .now)
            } else {
                try await session.stop()
            }
        }
        await gate.waitUntilEntered()
        await connection.rejectTurn()
        await errorWrite.waitUntilEntered()
        #expect(session.status == .stopping)
        #expect(await connection.prompts.count == 1)
        await errorWrite.open()
        await gate.open()
        try await operation.value
        if steering {
            await connection.waitForPrompts(2)
            #expect(await connection.prompts.last == [.init(text: "replacement")])
        } else {
            while session.status == .stopping { await Task.yield() }
            #expect(session.status == .idle && session.queuePaused)
        }
        await session.close()
    }

    @Test(arguments: [false, true]) func promptErrorWriteFailureOrCloseCannotRecoverToIdle(closing: Bool) async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        let gate = QueueGate()
        session.appendEvents = { events, id in
            if events.contains(where: {
                guard let event = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .failed = event { return true }
                return false
            }) {
                await gate.suspend()
                if !closing { throw CocoaError(.fileWriteOutOfSpace) }
            }
            return try await store.append(events, to: id)
        }
        await connection.rejectTurn()
        await gate.waitUntilEntered()
        let close = closing ? Task { await session.close() } : nil
        if closing { while session.status != .closed { await Task.yield() } }
        await gate.open()
        if let close {
            await close.value
            #expect(session.status == .closed && session.errorMessage == nil)
        } else {
            while session.status == .running { await Task.yield() }
            #expect(session.status == .failed && session.errorMessage != nil)
            await session.close()
        }
    }

    @Test(arguments: [false, true]) func promptErrorCancelsPendingRequestsDurably(failResolution: Bool) async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        let agentID = try #require(session.session.agentSessionID)
        let permission = Task {
            await session.requestPermission(
                for: .init(toolCallId: "write"),
                options: [.init(optionId: "allow", name: "Allow", kind: .allowOnce)],
                in: agentID
            )
        }
        let input = Task {
            await session.requestInput(
                .init(message: "Name", mode: .form(.init(properties: [:])), scope: .session(agentID, toolCallId: nil))
            )
        }
        while session.pendingPermissions.isEmpty || session.pendingInputs.isEmpty { await Task.yield() }
        if failResolution {
            session.appendEvents = { events, id in
                if events.contains(where: {
                    guard let event = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else {
                        return false
                    }
                    switch event {
                    case .permissionResolved, .inputResolved: return true
                    default: return false
                    }
                }) {
                    throw RPCError.internalError("Persistence failure, not a prompt response")
                }
                return try await store.append(events, to: id)
            }
        }
        await connection.rejectTurn()
        #expect(await permission.value == .cancelled)
        #expect(await input.value.action == .cancel)
        while session.status == .running { await Task.yield() }
        #expect(session.status == (failResolution ? .failed : .idle))
        #expect(session.pendingPermissions.isEmpty && session.pendingInputs.isEmpty)
        if !failResolution {
            let restored = try await SessionController.restore(id: session.session.id, store: store)
            #expect(restored.transcript.unansweredPermissions.isEmpty && restored.transcript.unansweredInputs.isEmpty)
            #expect(restored.transcript.activeTurn == nil && restored.queuePaused)
        }
        await session.close()
    }

    @Test func promptErrorWaitsForPermissionAdmittedDuringItsWrite() async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = Task { try await session.send([.init(text: "start")]) }
        await connection.waitForPrompts(1)
        let admission = QueueGate(), resolution = QueueGate()
        session.appendEvents = { events, id in
            for event in events {
                switch try JSONDecoder().decode(SessionEvent.self, from: event.payload) {
                case .permissionRequested: await admission.suspend()
                case .permissionResolved: await resolution.suspend()
                default: break
                }
            }
            return try await store.append(events, to: id)
        }
        let agentID = try #require(session.session.agentSessionID)
        let permission = Task {
            await session.requestPermission(
                for: .init(toolCallId: "write"),
                options: [.init(optionId: "allow", name: "Allow", kind: .allowOnce)],
                in: agentID
            )
        }
        await admission.waitUntilEntered()
        await connection.rejectTurn()
        while !session.queuePaused { await Task.yield() }
        await admission.open()
        await resolution.waitUntilEntered()
        #expect(session.status == .running)
        await resolution.open()
        #expect(await permission.value == .cancelled)
        await #expect(throws: RPCError.self) { try await turn.value }
        #expect(session.status == .idle && session.pendingPermissions.isEmpty)
        let restored = try await SessionController.restore(id: session.session.id, store: store)
        #expect(restored.transcript.unansweredPermissions.isEmpty)
        await session.close()
    }
    @Test func concurrentQueueChangesAndDeletionDoNotLoseMessages() async throws {
        let (session, _, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.stop()
        async let first: Void = session.submit([.init(text: "first")])
        async let second: Void = session.submit([.init(text: "second")])
        _ = try await (first, second)
        #expect(Set(session.queuedPrompts.map(\.text)) == ["first", "second"])
        let removed = try #require(session.queuedPrompts.first)
        try await session.removeQueuedPrompt(removed.id)
        let restored = try await SessionController.restore(id: session.session.id, store: store)
        #expect(restored.queuedPrompts == session.queuedPrompts)
        #expect(restored.queuedPrompts.count == 1)
        await #expect(throws: SessionController.SessionError.emptyPrompt) {
            try await session.submit([.init(text: " ")])
        }
        await #expect(throws: SessionController.SessionError.emptyPrompt) {
            try await session.updateQueuedPrompt(session.queuedPrompts[0].id, text: "")
        }
        await session.close()
    }

    @Test func failedAtomicDequeuePreservesTheQueueOnDisk() async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        try await session.submit([.init(text: "retained")])
        session.appendEvents = { events, id in
            if events.contains(where: {
                guard let event = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .promptMessage = event { return true }
                return false
            }) {
                throw QueueFailure()
            }
            return try await store.append(events, to: id)
        }
        await connection.finish(.endTurn)
        while session.status != .failed { await Task.yield() }
        let restored = try await SessionController.restore(id: session.session.id, store: store)
        #expect(restored.queuedPrompts.map(\.text) == ["retained"])
        #expect(restored.transcript.items.compactMap(\.message).count == 1)
        #expect(await connection.prompts.count == 1)
        await session.close()
    }

    @Test func manualStopSupersedesSteeringWhileCancelIsPending() async throws {
        let (session, connection, _, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        try await session.submit([.init(text: "retained")])
        let gate = QueueGate()
        await connection.suspendCancellation(on: gate)
        let steering = Task { try await session.submit([.init(text: "draft")], intent: .allNow) }
        await gate.waitUntilEntered()
        try await session.stop()
        await gate.open()
        await #expect(throws: SessionController.SessionError.invalidState) { try await steering.value }
        #expect(session.status == .idle && session.queuePaused)
        #expect(session.queuedPrompts.map(\.text) == ["retained"])
        #expect(await connection.prompts.count == 1)
        await session.close()
    }

    @Test func turnCompletionWaitsForAnAcceptedQueueAppend() async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        let gate = QueueGate()
        session.appendEvents = { events, id in
            if events.contains(where: {
                guard let event = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .queueChanged = event { return true }
                return false
            }) {
                await gate.suspend()
            }
            return try await store.append(events, to: id)
        }
        let submission = Task { try await session.submit([.init(text: "racing")]) }
        await gate.waitUntilEntered()
        await connection.finish(.endTurn)
        // Suspend only the accepted append; draining is the next queue transaction.
        session.appendEvents = { try await store.append($0, to: $1) }
        await gate.open()
        try await submission.value
        await connection.waitForPrompts(2)
        #expect(await connection.prompts.last == [.init(text: "racing")])
        #expect(session.queuedPrompts.isEmpty)
        await session.close()
    }

    @Test func allNowCanSendOnlyTheQueueAndEmptyHistoryContinuesNormally() async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.stop()
        try await session.submit([.init(text: "only queued")])
        try await session.submit([], intent: .allNow)
        await connection.waitForPrompts(1)
        #expect(session.queuePaused && session.queuedPrompts.isEmpty)
        await session.close()
        let continued = try await SessionController.history(id: session.session.id, store: store)
        let reopened = QueueConnection()
        try await continued.reopen(connection: reopened, client: .init(name: "test", version: "1"))
        // An explicitly paused empty queue remains paused, but can be resumed without a draft.
        try await continued.resumeQueue()
        #expect(!continued.queuePaused)
        try await continued.submit([.init(text: "new")])
        await reopened.waitForPrompts(1)
        await continued.close()
    }

    @Test(arguments: ["stop", "finish", "error", "stop-error"])
    func injectionPreparationSurvivesStopOrTurnCompletion(outcome: String) async throws {
        let stop = outcome.hasPrefix("stop")
        let (session, connection, store, directory) = try await live(strategy: .inject)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        try await session.submit([.init(text: "retained")])
        let gate = QueueGate()
        session.appendEvents = { events, id in
            if events.contains(where: {
                guard let event = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .injectionPrepared = event { return true }
                return false
            }) {
                await gate.suspend()
            }
            return try await store.append(events, to: id)
        }
        let steering = Task { try await session.submit([.init(text: "draft")], intent: .allNow) }
        await gate.waitUntilEntered()
        let stopping: Task<Void, any Error>?
        if stop {
            stopping = Task { try await session.stop() }
            while session.status != .stopping { await Task.yield() }
            if outcome == "stop-error" { await connection.rejectTurn() }
        } else {
            stopping = nil
            if outcome == "error" { await connection.rejectTurn() } else { await connection.finish(.endTurn) }
        }
        session.appendEvents = { try await store.append($0, to: $1) }
        await gate.open()
        try await steering.value
        try await stopping?.value
        #expect(await connection.injections.isEmpty)
        if stop {
            while session.status != .idle { await Task.yield() }
            #expect(session.queuePaused)
            #expect(session.queuedPrompts.map(\.text) == ["retained", "draft"])
            #expect(session.transcript.items.compactMap(\.message).count == 1)
            let restored = try await SessionController.restore(id: session.session.id, store: store)
            #expect(restored.queuedPrompts == session.queuedPrompts)
        } else {
            await connection.waitForPrompts(2)
            #expect(session.status == .running)
            #expect(await connection.prompts.last == [.init(text: "retained"), .init(text: "draft")])
            #expect(session.queuedPrompts.isEmpty)
        }
        await session.close()
    }

    @Test func stopBeforeWirePromptRequeuesAndMarksComposedMessagesNotSent() async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.stop()
        try await session.submit([.init(text: "queued")])
        let gate = QueueGate()
        session.appendEvents = { events, id in
            if events.contains(where: {
                guard let event = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .promptMessage = event { return true }
                return false
            }) {
                await gate.suspend()
            }
            return try await store.append(events, to: id)
        }
        let submission = Task { try await session.submit([.init(text: "draft")], intent: .allNow) }
        await gate.waitUntilEntered()
        let stopping = Task { try await session.stop() }
        while session.status != .stopping { await Task.yield() }
        let later = Task { try await session.submit([.init(text: "later")]) }
        session.appendEvents = { try await store.append($0, to: $1) }
        await gate.open()
        try await submission.value
        try await stopping.value
        try await later.value
        while session.status != .idle { await Task.yield() }
        #expect(await connection.prompts.isEmpty)
        #expect(session.queuedPrompts.map(\.text) == ["queued", "draft", "later"])
        #expect(session.transcript.items.compactMap(\.message).allSatisfy { $0.notSent })
        let restored = try await SessionController.restore(id: session.session.id, store: store)
        #expect(restored.queuedPrompts == session.queuedPrompts)
        #expect(restored.transcript == session.transcript)
        await session.close()
    }

    @Test(arguments: [false, true]) func stopSupersedesEarlierOperationsWaitingBehindQueueCommit(
        resume: Bool
    ) async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        try await session.submit([.init(text: "queued")])
        let gate = QueueGate()
        session.appendEvents = { events, id in
            if events.contains(where: {
                guard let event = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .queueChanged = event { return true }
                return false
            }) {
                await gate.suspend()
            }
            return try await store.append(events, to: id)
        }
        let editing = Task { try await session.updateQueuedPrompt(session.queuedPrompts[0].id, text: "edited") }
        await gate.waitUntilEntered()
        var entered = false
        let operation = Task {
            entered = true
            if resume {
                try await session.resumeQueue()
            } else {
                try await session.submit([.init(text: "draft")], intent: .now)
            }
        }
        while !entered { await Task.yield() }
        let stopping = Task { try await session.stop() }
        while session.status != .stopping { await Task.yield() }
        session.appendEvents = { try await store.append($0, to: $1) }
        await gate.open()
        try await editing.value
        try await stopping.value
        await #expect(throws: SessionController.SessionError.invalidState) { try await operation.value }
        while session.status != .idle { await Task.yield() }
        #expect(session.queuePaused)
        #expect(session.queuedPrompts.map(\.text) == ["edited"])
        #expect(await connection.prompts.count == 1)
        await session.close()
    }

    @Test func rejectedInjectionKeepsPreparedDraftAndQueueForRecovery() async throws {
        let (session, connection, store, directory) = try await live(strategy: .inject)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        try await session.submit([.init(text: "queued")])
        await connection.rejectInjection()
        await #expect(throws: ACP.SteeringError.injectionUnsupported) {
            try await session.submit([.init(text: "draft")], intent: .allNow)
        }
        #expect(session.status == .failed && session.queuePaused)
        #expect(session.queuedPrompts.map(\.text) == ["queued", "draft"])
        let restored = try await SessionController.restore(id: session.session.id, store: store)
        #expect(restored.queuedPrompts == session.queuedPrompts)
        #expect(restored.transcript.items.compactMap(\.message).count == 1)
        #expect(await connection.cancellationCount == 0)
        await session.close()
    }

    @Test func allNowIncludesMessagesReturnedByTheTurnItWaitsFor() async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.stop()
        try await session.submit([.init(text: "original")])
        let gate = QueueGate()
        session.appendEvents = { events, id in
            if events.contains(where: {
                guard let event = try? JSONDecoder().decode(SessionEvent.self, from: $0.payload) else { return false }
                if case .promptMessage = event { return true }
                return false
            }) {
                await gate.suspend()
            }
            return try await store.append(events, to: id)
        }
        let original = Task { try await session.submit([], intent: .allNow) }
        await gate.waitUntilEntered()
        let stopping = Task { try await session.stop() }
        while session.status != .stopping { await Task.yield() }
        let replacement = Task { try await session.submit([.init(text: "draft")], intent: .allNow) }
        session.appendEvents = { try await store.append($0, to: $1) }
        await gate.open()
        try await original.value
        try await stopping.value
        try await replacement.value
        await connection.waitForPrompts(1)
        #expect(await connection.prompts == [[.init(text: "original"), .init(text: "draft")]])
        #expect(session.queuedPrompts.isEmpty)
        await session.close()
    }

}
