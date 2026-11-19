import ACP
import Foundation
import JSONRPC
import Persistence
import TestSupport
import Testing

@testable import AgenthesiaCore

/// Records the wire calls in order: `prompt <texts>` and `<option>=<value>` for each accepted change.
private actor TurnConnection: ACP.AgentConnection {
    private(set) var calls: [String] = []
    private var options: [ACP.ConfigOption] = [
        select("mode", .mode, "ask", ["ask": "Ask", "auto": "Auto"]),
        select("model", .model, "small", ["small": "Small", "large": "Large"]),
        select("effort", .thoughtLevel, "high", ["high": "High", "max": "Max"]),
    ]
    private var refused: Set<ACP.ConfigOptionID> = []
    private var held: ACP.ConfigOptionID?
    private var release: CheckedContinuation<Void, Never>?
    private var turn: CheckedContinuation<ACP.StopReason, any Error>?

    private static func select(
        _ id: String,
        _ category: ACP.ConfigOptionCategory,
        _ current: String,
        _ names: KeyValuePairs<String, String>
    ) -> ACP.ConfigOption {
        .init(
            id: id,
            name: id.capitalized,
            category: category,
            value: .select(currentValue: current, options: .flat(names.map { .init(value: $0.key, name: $0.value) }))
        )
    }

    func initialize(client: ACP.Implementation) async throws -> ACP.AgentProfile { .init(protocolVersion: 1) }
    func authenticate(methodId: ACP.AuthMethodID) async throws {}
    func logout() async throws {}
    func newSession(
        cwd: String,
        additionalDirectories: [String],
        mcpServers: [ACP.MCPServer]
    ) async throws -> ACP.SessionState {
        .init(sessionId: "turn", configOptions: options)
    }
    func reopenSession(
        _ sessionId: ACP.SessionID,
        cwd: String,
        additionalDirectories: [String],
        mcpServers: [ACP.MCPServer]
    ) async throws -> ACP.ReopenedSession {
        .resumed(.init(sessionId: sessionId, configOptions: options))
    }
    func listSessions(cwd: String?) async throws -> [ACP.SessionInfo] { [] }
    func closeSession(_ sessionId: ACP.SessionID) async throws {}
    func deleteSession(_ sessionId: ACP.SessionID) async throws {}
    func prompt(_ content: [ACP.ContentBlock], in sessionId: ACP.SessionID) async throws -> ACP.StopReason {
        let texts = content.compactMap { if case .text(let text) = $0 { text.text } else { nil } }
        calls.append("prompt " + texts.joined(separator: "+"))
        return try await withCheckedThrowingContinuation { turn = $0 }
    }
    func cancel(_ sessionId: ACP.SessionID) async throws { finish(.cancelled) }
    func close() async {
        turn?.resume(throwing: CancellationError())
        turn = nil
        open()
    }
    func setConfigOption(
        _ configId: ACP.ConfigOptionID,
        to value: ACP.ConfigValue,
        in sessionId: ACP.SessionID
    ) async throws -> [ACP.ConfigOption] {
        if held == configId {
            held = nil
            await withCheckedContinuation { release = $0 }
        }
        if refused.contains(configId) { throw RPCError.invalidParams("Not now") }
        guard let index = options.firstIndex(where: { $0.id == configId }),
            case .select(_, let choices) = options[index].value, case .select(let wanted) = value
        else { throw RPCError.invalidParams() }
        options[index].value = .select(currentValue: wanted, options: choices)
        calls.append("\(configId)=\(wanted)")
        return options
    }

    func refuse(_ ids: Set<ACP.ConfigOptionID>) { refused = ids }
    /// The next change of `id` waits for `open()`.
    func hold(_ id: ACP.ConfigOptionID) { held = id }
    func open() {
        release?.resume()
        release = nil
    }
    func finish(_ reason: ACP.StopReason) {
        turn?.resume(returning: reason)
        turn = nil
    }
    func waitUntilPrompting() async { while turn == nil { await Task.yield() } }
    func waitUntilHolding() async { while release == nil { await Task.yield() } }
    func waitForCalls(_ count: Int) async { while calls.count < count { await Task.yield() } }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct ConfigDuringTurnTests {
    private func live() async throws -> (SessionController, TurnConnection, PersistenceStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "config-turn-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(databaseURL: directory.appending(path: "history.sqlite"))
        let project = ProjectRecord(name: "Config", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Config", executable: "mock")
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        let session = SessionController(
            session: .init(projectID: project.id, agentInstallID: agent.id, workingDirectory: directory.path),
            store: store
        )
        let connection = TurnConnection()
        try await session.start(connection: connection, client: .init(name: "test", version: "1"))
        return (session, connection, store, directory)
    }

    /// Starts a turn with the prompt `work` and waits until the agent has it.
    private func running() async throws -> (SessionController, TurnConnection, PersistenceStore, URL) {
        let fixture = try await live()
        try await fixture.0.submit([.init(text: "work")])
        await fixture.1.waitUntilPrompting()
        return fixture
    }

    private func current(_ id: ACP.ConfigOptionID, in session: SessionController) -> String? {
        guard case .select(let value, _) = session.transcript.configOptions.first(where: { $0.id == id })?.value
        else { return nil }
        return value
    }

    @Test func theModeChangesAtOnceDuringATurn() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("mode", to: .select("auto"))
        #expect(current("mode", in: session) == "auto")
        #expect(session.pendingConfig.isEmpty)
        #expect(session.status == .running)
        await connection.finish(.endTurn)
        try await waitUntil { session.status == .idle }
        #expect(await connection.calls == ["prompt work", "mode=auto"])
        await session.close()
    }

    @Test func aModeChangeLeavesAWaitingPermissionRequestOnTheCard() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agentID = try #require(session.session.agentSessionID)
        let answer = Task {
            await session.requestPermission(
                for: .init(toolCallId: "t"),
                options: [.init(optionId: "ok", name: "OK", kind: .allowOnce)],
                in: agentID
            )
        }
        try await waitUntil { !session.pendingPermissions.isEmpty }
        try await session.setConfigOption("mode", to: .select("auto"))
        #expect(current("mode", in: session) == "auto")
        let request = try #require(session.pendingPermissions.first)
        #expect(session.pendingPermissions.count == 1)
        #expect(session.answerPermission(request.id, with: "ok"))
        #expect(await answer.value == .selected("ok"))
        await connection.finish(.endTurn)
        await session.close()
    }

    @Test func aModeTheAgentRefusesDuringATurnChangesFromTheNextTurn() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        await connection.refuse(["mode"])
        try await session.setConfigOption("mode", to: .select("auto"))
        #expect(session.pendingConfig == ["mode": .select("auto")])
        #expect(current("mode", in: session) == "ask")
        #expect(session.configError == nil)
        #expect(session.isModeDeferred)
        await connection.refuse([])
        try await session.submit([.init(text: "next")])
        await connection.finish(.endTurn)
        await connection.waitForCalls(3)
        #expect(await connection.calls == ["prompt work", "mode=auto", "prompt next"])
        #expect(session.pendingConfig.isEmpty && !session.isModeDeferred)
        #expect(current("mode", in: session) == "auto")
        await session.close()
    }

    @Test func pendingChangesApplyInTheAgentsOrderBeforeTheQueuedPrompt() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("effort", to: .select("max"))
        try await session.setConfigOption("model", to: .select("large"))
        #expect(session.pendingConfig == ["model": .select("large"), "effort": .select("max")])
        #expect(current("model", in: session) == "small")
        try await session.submit([.init(text: "queued")])
        #expect(await connection.calls == ["prompt work"])
        await connection.finish(.endTurn)
        await connection.waitForCalls(4)
        #expect(await connection.calls == ["prompt work", "model=large", "effort=max", "prompt queued"])
        #expect(session.pendingConfig.isEmpty)
        #expect(current("model", in: session) == "large")
        await session.close()
    }

    @Test func aPromptTypedWhileThePendingChangeAppliesWaitsForIt() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("model", to: .select("large"))
        await connection.hold("model")
        await connection.finish(.endTurn)
        await connection.waitUntilHolding()
        #expect(session.status == .idle)
        let typed = Task { try await session.submit([.init(text: "typed")]) }
        await Task.yield()
        #expect(await connection.calls == ["prompt work"])
        await connection.open()
        try await typed.value
        await connection.waitForCalls(3)
        #expect(await connection.calls == ["prompt work", "model=large", "prompt typed"])
        await session.close()
    }

    @Test func choosingTheConfirmedValueDropsThePendingChange() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("model", to: .select("large"))
        try await session.setConfigOption("model", to: .select("small"))
        #expect(session.pendingConfig.isEmpty)
        await connection.finish(.endTurn)
        try await waitUntil { session.status == .idle }
        try await session.submit([.init(text: "next")])
        await connection.waitForCalls(2)
        #expect(await connection.calls == ["prompt work", "prompt next"])
        await session.close()
    }

    @Test func aPendingChangeRefusedAtTheTurnsEndPausesTheQueue() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("model", to: .select("large"))
        try await session.submit([.init(text: "queued")])
        await connection.refuse(["model"])
        await connection.finish(.endTurn)
        try await waitUntil { session.configError != nil }
        #expect(session.configError?.summary == "The agent refused Model: Large; the queue is paused.")
        #expect(session.configError?.details?.contains("Not now") == true)
        #expect(session.queuePaused && session.transcript.queuePaused)
        #expect(session.queuedPrompts.map(\.content) == [[.init(text: "queued")]])
        #expect(session.pendingConfig.isEmpty)
        #expect(current("model", in: session) == "small")
        #expect(await connection.calls == ["prompt work"])
        await session.close()
    }

    @Test func aPendingChangeIsAppliedOnceStopLeavesTheSessionIdle() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("model", to: .select("large"))
        try await session.stop()
        try await waitUntil { session.pendingConfig.isEmpty }
        #expect(await connection.calls == ["prompt work", "model=large"])
        #expect(current("model", in: session) == "large")
        #expect(session.status == .idle)
        await session.close()
    }

    @Test func theQueueWaitsForAModeChangeInFlightWhenTheTurnEnds() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        await connection.hold("mode")
        let change = Task { try await session.setConfigOption("mode", to: .select("auto")) }
        await connection.waitUntilHolding()
        #expect(session.isChangingConfig)
        try await session.submit([.init(text: "queued")])
        await connection.finish(.endTurn)
        try await waitUntil { session.status == .idle }
        #expect(await connection.calls == ["prompt work"])
        await connection.open()
        try await change.value
        await connection.waitForCalls(3)
        #expect(await connection.calls == ["prompt work", "mode=auto", "prompt queued"])
        await session.close()
    }

    @Test func aPendingChangeIsNotStored() async throws {
        let (session, connection, store, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("model", to: .select("large"))
        await session.close()
        let replay = try await SessionController.history(id: session.session.id, store: store)
        #expect(replay.pendingConfig.isEmpty)
        #expect(current("model", in: replay) == "small")
        #expect(await connection.calls == ["prompt work"])
    }
}
