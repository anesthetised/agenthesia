import ACP
import ACPTesting
import Foundation
import JSONRPC
import Persistence
import Testing

@testable import AgenthesiaCore

/// Starting and continuing a session whose agent requires sign-in (ADR-0033).
@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionSignInTests {
    private final class Fixture: Sendable {
        let directory: URL
        let store: PersistenceStore
        let project = ProjectRecord(name: "Test", rootPath: "/tmp/sign-in-test")
        let install = AgentInstallRecord(name: "Mock", executable: "MockAgent")

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "sign-in-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try PersistenceStore(databaseURL: directory.appending(path: "history.sqlite"))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func seed() async throws -> SessionRecord {
            try await store.createProject(project)
            try await store.createAgentInstall(install)
            return SessionRecord(projectID: project.id, agentInstallID: install.id, workingDirectory: project.rootPath)
        }
    }

    private static let client = ACP.Implementation(name: "test", version: "1")

    private static func signedOutAgent() -> EchoAgent {
        var options = EchoAgent.Options()
        options.requiresAuthentication = true
        options.reopensUnknownSessions = true
        return EchoAgent(options: options)
    }

    private func connect(_ agent: EchoAgent, to controller: SessionController) async -> ACP.V1.AgentConnectionAdapter {
        let (server, client) = InMemoryTransport.pair()
        Task { await agent.serve(server) }
        return await ACP.V1.AgentConnectionAdapter(transport: client, delegate: controller)
    }

    @Test func startWaitsForSignInWithoutWritingAndRetriesOnTheSameConnection() async throws {
        let fixture = try Fixture()
        let controller = SessionController(session: try await fixture.seed(), store: fixture.store)
        let connection = await connect(Self.signedOutAgent(), to: controller)
        await #expect(throws: SessionController.SessionError.authenticationRequired) {
            try await controller.start(connection: connection, client: Self.client)
        }
        #expect(controller.status == .ready)
        #expect(controller.errorMessage == nil)
        #expect(controller.profile?.authMethods.compactMap(\.id) == ["mock-login"])
        #expect(try await fixture.store.session(id: controller.session.id) == nil)

        // Still signed out: the controller stays ready for another attempt.
        await #expect(throws: SessionController.SessionError.authenticationRequired) { try await controller.retry() }
        #expect(controller.status == .ready)

        try await connection.authenticate(methodId: "mock-login")
        try await controller.retry()
        #expect(controller.status == .idle)
        #expect(try await fixture.store.session(id: controller.session.id) != nil)
        try await controller.send([.init(text: "hello")])
        #expect(controller.transcript.items.last?.message?.text == "Echo: hello")
        await controller.close()
    }

    @Test func startsAgainOnANewConnectionAfterATerminalSignIn() async throws {
        let fixture = try Fixture()
        let agent = Self.signedOutAgent()
        let controller = SessionController(session: try await fixture.seed(), store: fixture.store)
        let first = await connect(agent, to: controller)
        await #expect(throws: SessionController.SessionError.authenticationRequired) {
            try await controller.start(connection: first, client: Self.client)
        }
        await first.close()
        // A terminal method signs in outside the connection; the agent is then launched again.
        let terminal = await connect(agent, to: controller)
        _ = try await terminal.initialize(client: Self.client)
        try await terminal.authenticate(methodId: "mock-login")
        await terminal.close()

        try await controller.start(connection: await connect(agent, to: controller), client: Self.client)
        #expect(controller.status == .idle)
        await controller.close()
    }

    @Test func continuingWaitsForSignInWithoutWriting() async throws {
        let fixture = try Fixture()
        let seeded = try await fixture.seed()
        let saved = SessionRecord(
            id: seeded.id,
            projectID: seeded.projectID,
            agentInstallID: seeded.agentInstallID,
            agentSessionID: "saved",
            workingDirectory: seeded.workingDirectory
        )
        try await fixture.store.createSession(saved)
        _ = try await fixture.store.append([try SessionEvent.started(configOptions: []).storedEvent()], to: saved.id)
        let before = try await fixture.store.events(in: saved.id)

        let controller = try await SessionController.history(id: saved.id, store: fixture.store)
        let connection = await connect(Self.signedOutAgent(), to: controller)
        await #expect(throws: SessionController.SessionError.authenticationRequired) {
            try await controller.reopen(connection: connection, client: Self.client)
        }
        #expect(controller.status == .ready)
        #expect(try await fixture.store.events(in: saved.id) == before)

        try await connection.authenticate(methodId: "mock-login")
        try await controller.retry()
        #expect(controller.status == .idle)
        #expect(controller.transcript.items.last?.reopenedAt != nil)
        await controller.close()
    }

    @Test func closingWhileWaitingForSignInEndsTheController() async throws {
        let fixture = try Fixture()
        let controller = SessionController(session: try await fixture.seed(), store: fixture.store)
        let connection = await connect(Self.signedOutAgent(), to: controller)
        await #expect(throws: SessionController.SessionError.authenticationRequired) {
            try await controller.start(connection: connection, client: Self.client)
        }
        await controller.close()
        #expect(controller.status == .closed)
        await #expect(throws: SessionController.SessionError.invalidState) { try await controller.retry() }
    }

    @Test func retryNeedsAnEarlierAttempt() async throws {
        let fixture = try Fixture()
        let controller = SessionController(session: try await fixture.seed(), store: fixture.store)
        await #expect(throws: SessionController.SessionError.invalidState) { try await controller.retry() }
    }
}
