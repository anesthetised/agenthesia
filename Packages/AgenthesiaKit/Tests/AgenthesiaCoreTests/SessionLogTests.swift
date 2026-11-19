import ACP
import ACPTesting
import Foundation
import JSONRPC
import Persistence
import TestSupport
import Testing

@testable import AgenthesiaCore

/// One writer per session (#355): the controller and the manager's own appends share the session's log.
@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionLogTests {
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "session-log-\(UUID())")
        let store: PersistenceStore
        let agent = EchoAgent(
            options: {
                var options = EchoAgent.Options(); options.resumeSession = true; return options
            }()
        )

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try PersistenceStore(databaseURL: directory.appending(path: "history.sqlite"))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// A started session writing through a log of its own, as one from `SessionManager`.
        func live() async throws -> SessionController {
            let project = ProjectRecord(name: "Test", rootPath: directory.path)
            let install = AgentInstallRecord(name: "Mock", executable: "MockAgent")
            try await store.createProject(project)
            try await store.createAgentInstall(install)
            let session = SessionRecord(
                projectID: project.id,
                agentInstallID: install.id,
                workingDirectory: project.rootPath
            )
            let controller = SessionController(
                session: session,
                store: store,
                log: SessionLog(sessionID: session.id, store: store)
            )
            try await controller.start(connection: await connect(controller), client: .init(name: "test", version: "1"))
            return controller
        }

        func connect(_ controller: SessionController) async -> any ACP.AgentConnection {
            let (server, client) = InMemoryTransport.pair()
            Task { await agent.serve(server) }
            return await ACP.V1.AgentConnectionAdapter(transport: client, delegate: controller)
        }

        func replay(_ id: UUID) async throws -> TranscriptState {
            try await SessionController.restore(id: id, store: store).transcript
        }
    }

    private let pullRequest = PullRequest(url: URL(string: "https://github.com/o/r/pull/7")!, number: 7)

    /// Another writer appended between the loaded history and the reopen's first write: the controller loads the
    /// missing event instead of failing with `outOfOrder`.
    @Test func aGapBeforeAWriteIsLoaded() async throws {
        let fixture = try Fixture()
        let first = try await fixture.live()
        try await first.send([.init(text: "hello")])
        await first.close()
        let id = first.session.id

        let controller = try await SessionController.history(id: id, store: fixture.store)
        _ = try await fixture.store.append([pullRequest.storedEvent()], to: id)
        try await controller.reopen(
            connection: await fixture.connect(controller),
            client: .init(name: "test", version: "1")
        )
        #expect(controller.status == .idle)
        #expect(controller.transcript.pullRequest == pullRequest)
        #expect(controller.transcript == (try await fixture.replay(id)))
        await controller.close()
    }

    /// The pull request case of #355: an append while Continue loads the saved session reaches the new controller.
    @Test func anAppendDuringContinueReachesTheController() async throws {
        let fixture = try Fixture()
        let first = try await fixture.live()
        try await first.send([.init(text: "hello")])
        await first.close()
        let id = first.session.id
        let log = SessionLog(sessionID: id, store: fixture.store)

        let controller = try await SessionController.history(id: id, store: fixture.store, log: log)
        try await log.append([pullRequest.storedEvent()]).value
        #expect(controller.transcript.pullRequest == pullRequest)
        try await controller.reopen(
            connection: await fixture.connect(controller),
            client: .init(name: "test", version: "1")
        )
        #expect(controller.status == .idle)
        try await controller.send([.init(text: "again")])
        #expect(controller.status == .idle)
        #expect(controller.transcript == (try await fixture.replay(id)))
        await controller.close()
    }

    /// The controller's write is in flight when another caller appends: the second waits, and both keep call order.
    @Test func appendsFromTwoCallersKeepTheirOrder() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let log = controller.log
        let id = controller.session.id
        let store = fixture.store
        let gate = Gate()
        controller.appendEvents = { events, id in
            await gate.suspendOnce()
            return try await store.append(events, to: id)
        }
        let turn = Task { try await controller.send([.init(text: "hello")]) }
        await gate.waitUntilEntered()
        let foreign = log.append([try pullRequest.storedEvent()])
        for _ in 0..<10 { await Task.yield() }
        #expect(try await store.events(in: id).allSatisfy { $0.event.kind != PullRequest.kind })
        await gate.open()
        try await turn.value
        try await foreign.value
        let events = try await store.events(in: id)
        let prompt = try #require(
            events.lastIndex {
                (try? JSONDecoder().decode(SessionEvent.self, from: $0.event.payload))?.isPrompt == true
            }
        )
        #expect(events[prompt + 1].event.kind == PullRequest.kind)
        #expect(controller.status == .idle)
        #expect(controller.transcript.pullRequest == pullRequest)
        #expect(controller.transcript == (try await fixture.replay(id)))
        await controller.close()
    }

    /// A log append on a failed session is stored; the failed controller is left as it was.
    @Test func aFailedControllerIsNotUpdated() async throws {
        let fixture = try Fixture()
        let controller = try await fixture.live()
        let log = controller.log
        controller.appendEvents = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        await #expect(throws: CocoaError.self) { try await controller.send([.init(text: "lost")]) }
        #expect(controller.status == .failed)
        try await log.append([pullRequest.storedEvent()]).value
        #expect(controller.transcript.pullRequest == nil)
        #expect(try await fixture.replay(controller.session.id).pullRequest == pullRequest)
        await controller.close()
    }

    @Test func theManagerKeepsOneLogPerSession() async throws {
        let fixture = try Fixture()
        let manager = SessionManager(
            library: SessionLibrary(databaseURL: fixture.directory.appending(path: "h.sqlite"))
        )
        let id = UUID()
        let log = manager.log(for: id, store: fixture.store)
        #expect(manager.log(for: id, store: fixture.store) === log)
        #expect(manager.log(for: UUID(), store: fixture.store) !== log)
    }
}

extension SessionEvent {
    fileprivate var isPrompt: Bool { if case .prompt = self { true } else { false } }
}

/// Holds the first write until `open`; later writes pass.
private actor Gate {
    private var used = false
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func suspendOnce() async {
        guard !used else { return }
        used = true
        for waiter in entered { waiter.resume() }
        entered.removeAll()
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilEntered() async {
        if used { return }
        await withCheckedContinuation { entered.append($0) }
    }

    func open() { release?.resume(); release = nil }
}
