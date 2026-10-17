import ACP
import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore

private actor InteractionConnection: ACP.AgentConnection {
    private var promptResult: CheckedContinuation<ACP.StopReason, any Error>?
    private(set) var prompts: [[ACP.ContentBlock]] = []
    private var promptWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var configResult: CheckedContinuation<Void, Never>?
    private var configEntered = false
    private var configWaiters: [CheckedContinuation<Void, Never>] = []
    private let holdsConfig: Bool

    init(holdsConfig: Bool = false) { self.holdsConfig = holdsConfig }
    func initialize(client: ACP.Implementation) async throws -> ACP.AgentProfile { .init(protocolVersion: 1) }
    func authenticate(methodId: ACP.AuthMethodID) async throws {}
    func logout() async throws {}
    func newSession(
        cwd: String,
        additionalDirectories: [String],
        mcpServers: [ACP.MCPServer]
    ) async throws -> ACP.SessionState {
        .init(sessionId: "interaction", configOptions: [])
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
        try await withCheckedThrowingContinuation { continuation in
            promptResult = continuation
            prompts.append(content)
            let ready = promptWaiters.filter { $0.0 <= prompts.count }
            promptWaiters.removeAll { $0.0 <= prompts.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func waitForPrompts(_ count: Int) async {
        if prompts.count >= count { return }
        await withCheckedContinuation { promptWaiters.append((count, $0)) }
    }
    func cancel(_ sessionId: ACP.SessionID) async throws { finish() }
    func close() async { releaseConfig(); finish() }
    private func finish() { promptResult?.resume(returning: .cancelled); promptResult = nil }
    func setConfigOption(
        _ configId: ACP.ConfigOptionID,
        to value: ACP.ConfigValue,
        in sessionId: ACP.SessionID
    ) async throws -> [ACP.ConfigOption] {
        if holdsConfig {
            await withCheckedContinuation { continuation in
                configResult = continuation
                configEntered = true
                for waiter in configWaiters { waiter.resume() }
                configWaiters.removeAll()
            }
        }
        return [.init(id: configId, name: "Flag", value: .boolean(currentValue: true))]
    }
    func waitForConfig() async {
        if configEntered { return }
        await withCheckedContinuation { configWaiters.append($0) }
    }
    func releaseConfig() { configResult?.resume(); configResult = nil }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionInteractionTests {
    private func live(
        holdsConfig: Bool = false
    ) async throws -> (SessionController, InteractionConnection, PersistenceStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "interactions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(databaseURL: directory.appending(path: "history.sqlite"))
        let project = ProjectRecord(name: "Interactions", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Interaction", executable: "mock")
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        let controller = SessionController(
            session: .init(projectID: project.id, agentInstallID: agent.id, workingDirectory: directory.path),
            store: store
        )
        let connection = InteractionConnection(holdsConfig: holdsConfig)
        try await controller.start(connection: connection, client: .init(name: "test", version: "1"))
        return (controller, connection, store, directory)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    @Test func queueSubmissionCannotOvertakeAnAcceptedConfigChange() async throws {
        let (session, connection, _, directory) = try await live(holdsConfig: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let changing = Task { try await session.setConfigOption("flag", to: .boolean(true)) }
        await connection.waitForConfig()
        await #expect(throws: SessionController.SessionError.invalidState) {
            try await session.submit([.init(text: "too early")])
        }
        #expect(await connection.prompts.isEmpty)
        await connection.releaseConfig()
        try await changing.value
        try await session.submit([.init(text: "after confirmation")])
        await connection.waitForPrompts(1)
        #expect(await connection.prompts == [[.init(text: "after confirmation")]])
        await session.close()
    }

    @Test func queueResumeWaitsForConfigConfirmationBeforeDispatch() async throws {
        let (session, connection, _, directory) = try await live(holdsConfig: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.submit([.init(text: "working")])
        await connection.waitForPrompts(1)
        try await session.submit([.init(text: "kept during config")])
        try await session.stop()
        try await eventually { session.status == .idle }
        let changing = Task { try await session.setConfigOption("flag", to: .boolean(true)) }
        await connection.waitForConfig()
        let resuming = Task { try await session.resumeQueue() }
        try await eventually { !session.queuePaused }
        #expect(await connection.prompts.count == 1)
        await connection.releaseConfig()
        try await changing.value
        try await resuming.value
        await connection.waitForPrompts(2)
        #expect(await connection.prompts.last == [.init(text: "kept during config")])
        await session.close()
    }

    @Test func steeringCancelsFormsAndStopPreservesQueuedAttachmentsThroughContinue() async throws {
        let (session, connection, store, directory) = try await live()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("flag", to: .boolean(true))
        try await session.submit([.init(text: "start")])
        await connection.waitForPrompts(1)
        let attachment = ACP.ContentBlock.resourceLink(.init(uri: "file:///tmp/review.txt", name: "review.txt"))
        let queued: [ACP.ContentBlock] = [.init(text: "review later"), attachment]
        try await session.submit(queued)
        let request = ACP.ElicitationRequest(
            message: "Choose a name",
            mode: .form(.init(properties: ["name": .string(.init())])),
            scope: .session("interaction", toolCallId: nil)
        )
        let answer = Task { await session.requestInput(request) }
        try await eventually { !session.pendingInputs.isEmpty }
        try await session.submit([.init(text: "redirect")], intent: .now)
        await connection.waitForPrompts(2)
        #expect(await answer.value.action == .cancel)
        #expect(session.pendingInputs.isEmpty)
        #expect(session.queuedPrompts.map(\.content) == [queued])
        try await session.stop()
        try await eventually { session.status == .idle }
        #expect(session.queuePaused)
        await session.close()
        let restored = try await SessionController.restore(id: session.session.id, store: store)
        #expect(restored.queuePaused && restored.queuedPrompts.map(\.content) == [queued])
        #expect(restored.transcript.items.compactMap(\.input).last?.response?.action == .cancel)
        let continued = try await SessionController.history(id: session.session.id, store: store)
        let next = InteractionConnection()
        try await continued.reopen(connection: next, client: .init(name: "test", version: "1"))
        #expect(continued.queuePaused && continued.pendingInputs.isEmpty)
        #expect(await next.prompts.isEmpty)
        try await continued.resumeQueue()
        await next.waitForPrompts(1)
        #expect(await next.prompts == [queued])
        await continued.close()
    }
}
