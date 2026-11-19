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
    private var holdsCancel = false
    private var cancelRelease: CheckedContinuation<Void, Never>?

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
    func cancel(_ sessionId: ACP.SessionID) async throws {
        if holdsCancel { await withCheckedContinuation { cancelRelease = $0 } }
        finish(.cancelled)
    }
    func close() async {
        turn?.resume(throwing: CancellationError())
        turn = nil
        open()
        openCancel()
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
    /// `cancel` waits for `openCancel()`, so the session stays stopping.
    func holdCancel() { holdsCancel = true }
    func openCancel() {
        cancelRelease?.resume()
        cancelRelease = nil
    }
    func waitUntilCancelling() async { while cancelRelease == nil { await Task.yield() } }
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

    private func pauses(_ store: PersistenceStore, _ session: SessionController) async throws -> Int {
        try await store.events(in: session.session.id).count {
            guard $0.event.kind == SessionEvent.kind,
                case .queuePaused(true) = try? JSONDecoder().decode(SessionEvent.self, from: $0.event.payload)
            else { return false }
            return true
        }
    }

    private func current(_ id: ACP.ConfigOptionID, in session: SessionController) -> String? {
        guard case .select(let value, _) = session.transcript.configOptions.first(where: { $0.id == id })?.value
        else { return nil }
        return value
    }

    @Test func theModeChangesAtOnceDuringATurn() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!session.modeChangedDuringTurn)
        try await session.setConfigOption("mode", to: .select("auto"))
        #expect(current("mode", in: session) == "auto")
        #expect(session.pendingConfig.isEmpty)
        #expect(session.status == .running)
        #expect(session.modeChangedDuringTurn && !session.isModeDeferred)
        await connection.finish(.endTurn)
        try await waitUntil { session.status == .idle }
        #expect(!session.modeChangedDuringTurn)
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

    @Test func theModeChangesAtOnceWhileTheTurnStops() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        await connection.holdCancel()
        let stopping = Task { try await session.stop() }
        await connection.waitUntilCancelling()
        #expect(session.status == .stopping)
        try await session.setConfigOption("mode", to: .select("auto"))
        try await session.setConfigOption("model", to: .select("large"))
        #expect(await connection.calls == ["prompt work", "mode=auto"])
        #expect(session.pendingConfig == ["model": .select("large")])
        await connection.openCancel()
        try await stopping.value
        await connection.waitForCalls(3)
        #expect(await connection.calls == ["prompt work", "mode=auto", "model=large"])
        await session.close()
    }

    @Test func sendNowAppliesThePendingChangeBeforeTheSteeringPrompt() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("model", to: .select("large"))
        try await session.submit([.init(text: "steer")], intent: .now)
        #expect(await connection.calls == ["prompt work", "model=large", "prompt steer"])
        #expect(session.pendingConfig.isEmpty)
        await session.close()
    }

    @Test func sendNowWithARefusedPendingChangeIsNotSentAndPausesTheQueue() async throws {
        let (session, connection, store, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("model", to: .select("large"))
        try await session.setConfigOption("effort", to: .select("max"))
        await connection.refuse(["model", "effort"])
        await #expect(throws: SessionController.SessionError.configRefused) {
            try await session.submit([.init(text: "steer")], intent: .now)
        }
        #expect(session.configError?.summary == "The agent refused Model: Large, Effort: Max; the queue is paused.")
        #expect(session.queuePaused && session.status == .idle)
        #expect(await connection.calls == ["prompt work"])
        // The interrupted turn's Stop did not pause the queue; the refusal did, once.
        #expect(try await pauses(store, session) == 1)
        await session.close()
    }

    @Test func stopDuringSendNowStillAppliesThePendingChange() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("model", to: .select("large"))
        await connection.holdCancel()
        let steering = Task { try await session.submit([.init(text: "steer")], intent: .now) }
        await connection.waitUntilCancelling()
        try await session.stop()
        await connection.openCancel()
        await #expect(throws: SessionController.SessionError.invalidState) { try await steering.value }
        try await waitUntil { session.pendingConfig.isEmpty }
        #expect(await connection.calls == ["prompt work", "model=large"])
        #expect(session.status == .idle)
        await session.close()
    }

    @Test func aRefusalAtTheTurnsEndWithAPausedQueueWritesNoSecondPause() async throws {
        let (session, connection, store, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("model", to: .select("large"))
        try await session.submit([.init(text: "queued")])
        await connection.refuse(["model"])
        try await session.stop()
        try await waitUntil { session.configError != nil }
        #expect(session.configError?.summary == "The agent refused Model: Large; the queue is paused.")
        #expect(try await pauses(store, session) == 1)
        await session.close()
    }

    @Test func theRefusalClearsWhenTheQueueResumesOrTheNextChangeStarts() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("model", to: .select("large"))
        try await session.submit([.init(text: "queued")])
        await connection.refuse(["model"])
        await connection.finish(.endTurn)
        try await waitUntil { session.configError != nil }
        await connection.refuse([])
        try await session.resumeQueue()
        #expect(session.configError == nil)
        await connection.waitForCalls(2)
        #expect(await connection.calls == ["prompt work", "prompt queued"])
        await connection.finish(.endTurn)
        try await waitUntil { session.status == .idle }
        await connection.refuse(["effort"])
        await #expect(throws: RPCError.self) { try await session.setConfigOption("effort", to: .select("max")) }
        #expect(session.configError != nil)
        try await session.setConfigOption("model", to: .select("large"))
        #expect(session.configError == nil)
        await session.close()
    }

    @Test func aPendingChangeTheAgentMakesItselfIsDropped() async throws {
        let (session, connection, _, directory) = try await running()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setConfigOption("model", to: .select("large"))
        var options = session.transcript.configOptions
        let index = try #require(options.firstIndex { $0.id == "model" })
        guard case .select(_, let choices) = options[index].value else { return }
        options[index].value = .select(currentValue: "large", options: choices)
        let update = ACP.SessionUpdate.configOptions(.init(configOptions: options))
        let raw = try JSONEncoder().encode(
            Message.notification(
                method: "session/update",
                params: try JSONValue(encoding: ACP.V1.SessionNotification(sessionId: "turn", update: update))
            )
        )
        await session.sessionUpdate(update, in: "turn", rawNotification: raw)
        #expect(session.pendingConfig.isEmpty)
        await connection.finish(.endTurn)
        try await waitUntil { session.status == .idle }
        #expect(await connection.calls == ["prompt work"])
        await session.close()
    }

    /// Through `LiveSession`, as the composer sends: the refusal shows only as the controller's `configError`.
    @Test func aRefusedSendNowShowsNoSecondError() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "config-turn-live-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager(
            library: SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite"))
        )
        manager.environment = { (ProcessInfo.processInfo.environment, nil) }
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        let agent = AgentInstallRecord(name: "Mock", executable: binary.path, arguments: ["--reject-config"])
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        #expect(await owner.submit("slow"))
        try await waitUntil { controller.status == .running }
        try await controller.setConfigOption("model", to: .select("large"))
        #expect(!(await owner.submit("now", intent: .now)))
        #expect(owner.errorMessage == nil)
        #expect(controller.configError?.summary == "The agent refused Model: Large; the queue is paused.")
        await manager.closeAll()
    }
}
