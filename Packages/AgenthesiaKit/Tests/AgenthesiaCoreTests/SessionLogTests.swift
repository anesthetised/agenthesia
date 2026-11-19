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
        let manager: SessionManager
        let store: PersistenceStore
        let agent = EchoAgent(
            options: {
                var options = EchoAgent.Options(); options.resumeSession = true; return options
            }()
        )

        init() async throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            manager = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
            store = try await manager.library.store()
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// A started session writing through the manager's log, as a live owner's does.
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
                log: try await manager.log(for: session.id)
            )
            try await controller.start(connection: await connect(controller), client: .init(name: "test", version: "1"))
            return controller
        }

        /// A session with one turn, ended, as Continue finds it.
        func saved() async throws -> UUID {
            let first = try await live()
            try await first.send([.init(text: "hello")])
            await first.close()
            return first.session.id
        }

        func reopen(_ controller: SessionController) async throws {
            try await controller.reopen(
                connection: await connect(controller),
                client: .init(name: "test", version: "1")
            )
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
    private let waiting = QueuedPrompt(content: [.init(text: "waiting")])

    /// Another writer appended between the loaded history and the reopen's first write: the controller loads the
    /// missing event instead of failing with `outOfOrder`.
    @Test func aGapBeforeAWriteIsLoaded() async throws {
        let fixture = try await Fixture()
        let id = try await fixture.saved()
        let controller = try await SessionController.history(id: id, store: fixture.store)
        _ = try await fixture.store.append([pullRequest.storedEvent()], to: id)
        try await fixture.reopen(controller)
        #expect(controller.status == .idle)
        #expect(controller.transcript.pullRequest == pullRequest)
        #expect(controller.transcript == (try await fixture.replay(id)))
        await controller.close()
    }

    /// A queued message written past the log before the reopen is in the baseline, so the queue stays paused.
    @Test func theBaselineSeesAQueueWrittenPastTheLog() async throws {
        let fixture = try await Fixture()
        let id = try await fixture.saved()
        let controller = try await SessionController.history(id: id, store: fixture.store)
        _ = try await fixture.store.append([SessionEvent.queueChanged([waiting]).storedEvent()], to: id)
        try await fixture.reopen(controller)
        #expect(controller.status == .idle)
        #expect(controller.queuePaused)
        #expect(controller.transcript.queuedPrompts == [waiting])
        #expect(controller.transcript == (try await fixture.replay(id)))
        await controller.close()
    }

    /// The pull request case of #355: an append while Continue loads the saved session reaches the new controller.
    @Test func anAppendDuringContinueReachesTheController() async throws {
        let fixture = try await Fixture()
        let id = try await fixture.saved()
        let log = try await fixture.manager.log(for: id)
        let controller = try await SessionController.history(id: id, store: fixture.store, log: log)
        try await fixture.manager.append([pullRequest.storedEvent()], to: id)
        #expect(controller.transcript.pullRequest == pullRequest)
        try await fixture.reopen(controller)
        #expect(controller.status == .idle)
        try await controller.send([.init(text: "again")])
        #expect(controller.status == .idle)
        #expect(controller.transcript == (try await fixture.replay(id)))
        await controller.close()
    }

    /// History loads as a step of the log, after an append reserved before it.
    @Test func historyLoadsAfterAStepReservedBeforeIt() async throws {
        let fixture = try await Fixture()
        let id = try await fixture.saved()
        let log = try await fixture.manager.log(for: id)
        let gate = Gate()
        _ = log.run { await gate.suspendOnce() }
        let foreign = log.append([try pullRequest.storedEvent()])
        let loaded = Flag()
        let loading = Task {
            defer { loaded.value = true }
            return try await SessionController.history(id: id, store: fixture.store, log: log)
        }
        await gate.waitUntilEntered()
        for _ in 0..<10 { await Task.yield() }
        #expect(!loaded.value)
        await gate.open()
        try await foreign.value
        let controller = try await loading.value
        #expect(controller.transcript.pullRequest == pullRequest)
        #expect(controller.transcript == (try await fixture.replay(id)))
    }

    /// An append reserved before the reopen's baseline and still pending while the agent reopens is in the baseline.
    @Test func theBaselineFollowsAPendingStep() async throws {
        let fixture = try await Fixture()
        let id = try await fixture.saved()
        let log = try await fixture.manager.log(for: id)
        let controller = try await SessionController.history(id: id, store: fixture.store, log: log)
        let gate = Gate()
        _ = log.run { await gate.suspendOnce() }
        let foreign = log.append([try SessionEvent.queueChanged([waiting]).storedEvent()])
        let reopening = Task { try await fixture.reopen(controller) }
        // The baseline's step is reserved once the agent has reopened the session.
        try await waitUntil { log.tail != foreign }
        await gate.open()
        try await reopening.value
        #expect(controller.queuePaused)
        #expect(controller.transcript.queuedPrompts == [waiting])
        #expect(controller.transcript == (try await fixture.replay(id)))
        await controller.close()
    }

    /// The controller's write is in flight when the manager appends: the manager's waits, and both keep call order.
    @Test func theControllerAndTheManagerShareOneOrder() async throws {
        let fixture = try await Fixture()
        let controller = try await fixture.live()
        let log = controller.log
        let id = controller.session.id
        #expect(try await fixture.manager.log(for: id) === log)
        let store = fixture.store
        let gate = Gate()
        controller.appendEvents = { events, id in
            await gate.suspendOnce()
            return try await store.append(events, to: id)
        }
        let turn = Task { try await controller.send([.init(text: "hello")]) }
        await gate.waitUntilEntered()
        let reserved = log.tail
        let foreign = Task { try await fixture.manager.append([pullRequest.storedEvent()], to: id) }
        try await waitUntil { log.tail != reserved }
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
        let fixture = try await Fixture()
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

    /// Another writer's event that the controller cannot apply fails it before the next step runs.
    @Test func aForeignEventThatCannotBeAppliedFailsTheControllerAtOnce() async throws {
        let fixture = try await Fixture()
        let controller = try await fixture.live()
        let stored = try await fixture.store.append(
            [NewEvent(kind: PullRequest.kind, payload: Data("{}".utf8))],
            to: controller.session.id
        )
        await controller.didAppend(stored)
        #expect(controller.status == .failed)
        #expect(controller.queuePaused)
        await #expect(throws: SessionController.SessionError.invalidState) {
            try await controller.send([.init(text: "refused")])
        }
        await controller.close()
    }
}

extension SessionEvent {
    fileprivate var isPrompt: Bool { if case .prompt = self { true } else { false } }
}

@MainActor private final class Flag { var value = false }

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
