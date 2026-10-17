public import ACP
public import Foundation
import JSONRPC
import Observation
public import Persistence

/// One live session. The caller owns the process and passes its connection using this controller as delegate.
/// Call `publishTranscript()` from the view's display link; terminal states always publish immediately.
@MainActor @Observable
public final class SessionController: ACP.AgentConnectionDelegate {
    public enum Status: Equatable, Sendable {
        case ready, starting, idle, running, stopping, readOnly, failed, closed
    }

    /// A request awaiting the user's choice, oldest first. Its transcript row carries the tool context.
    public struct PendingPermission: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let options: [ACP.PermissionOption]
    }

    /// A committed form awaiting an answer, oldest first. Draft values belong to the view.
    public struct PendingInput: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let request: ACP.ElicitationRequest
    }

    public enum SessionError: Error, Equatable {
        case invalidState
        case emptyPrompt
        case missingRawNotification
        case startupBufferFull
        case sessionNotFound
        case unsupportedAdditionalDirectories
        /// The agent can neither resume nor load sessions.
        case cannotReopen
    }

    public private(set) var isChangingConfig = false
    public enum SubmissionIntent: Equatable, Sendable { case whenReady, now, allNow }

    public var queuedPrompts: [QueuedPrompt] { transcript.queuedPrompts }
    public private(set) var queuePaused = false
    /// Turns that ended on their own, not by Stop; the sidebar compares it with what the user has seen.
    public private(set) var completedTurns = 0
    public private(set) var status: Status = .ready
    public private(set) var transcript = TranscriptState()
    /// Observed separately so window chrome does not re-render on every published transcript frame.
    public private(set) var title: String?
    public var errorMessage: String? { failure.map { String(describing: $0) } }
    public private(set) var session: SessionRecord
    public private(set) var profile: ACP.AgentProfile?
    public private(set) var pendingInputs: [PendingInput] = []
    public private(set) var pendingPermissions: [PendingPermission] = []
    /// Successful ACP writes invalidate file browsing without waiting for FSEvents delivery.
    public private(set) var fileRevision: UInt64 = 0
    /// Explicit roots for this launch; read-only history never re-enables filesystem access.
    public let additionalDirectories: [String]
    @ObservationIgnored var fileSystem: SessionFileSystem?

    func fileDidChange() { fileRevision &+= 1 }

    private var failure: (any Error)?
    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private var connection: (any ACP.AgentConnection)?
    @ObservationIgnored private var reduced = TranscriptState()
    @ObservationIgnored private var tail: Task<Void, any Error>?
    @ObservationIgnored private var configTask: Task<Void, any Error>?
    @ObservationIgnored private var turnTask: Task<Void, any Error>?
    @ObservationIgnored private var stopTask: Task<Void, any Error>?
    @ObservationIgnored private var turnID: UUID?
    @ObservationIgnored private var queueTask: Task<Void, any Error>?
    @ObservationIgnored private var steering = false
    @ObservationIgnored private var injectionTask: Task<Bool, any Error>?
    @ObservationIgnored private var stopGeneration = 0
    @ObservationIgnored private var promptStarted = false
    @ObservationIgnored private var recording = false
    @ObservationIgnored private var startupUpdates: [(ACP.SessionID, ACP.SessionUpdate, Data)] = []
    @ObservationIgnored private var startupBytes = 0
    @ObservationIgnored private var inputCloseWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var inputGeneration: UInt64 = 0
    @ObservationIgnored private var inputs: [UUID: Input] = [:]
    @ObservationIgnored private var permissions: [UUID: Permission] = [:]
    // Internal seam for deterministic disk-failure and suspended-write tests; production uses the store.
    @ObservationIgnored var createSession: @Sendable (SessionRecord) async throws -> Void
    @ObservationIgnored var appendEvents: @Sendable ([NewEvent], UUID) async throws -> [StoredEvent]

    /// The project and agent install must already exist. The draft session is inserted after session/new succeeds.
    public init(session: SessionRecord, store: PersistenceStore, additionalDirectories: [String] = []) {
        self.session = session
        self.store = store
        self.additionalDirectories = additionalDirectories
        createSession = { try await store.createSession($0) }
        appendEvents = { try await store.append($0, to: $1) }
    }

    public func start(connection: any ACP.AgentConnection, client: ACP.Implementation) async throws {
        guard status == .ready else { throw SessionError.invalidState }
        status = .starting
        self.connection = connection
        do {
            let profile = try await connection.initialize(client: client)
            guard status == .starting else { throw SessionError.invalidState }
            self.profile = profile
            guard additionalDirectories.isEmpty || profile.acceptsAdditionalDirectories else {
                throw SessionError.unsupportedAdditionalDirectories
            }
            let remote = try await connection.newSession(
                cwd: session.workingDirectory,
                additionalDirectories: additionalDirectories,
                mcpServers: []
            )
            guard status == .starting else { throw SessionError.invalidState }
            session = SessionRecord(
                id: session.id,
                projectID: session.projectID,
                agentInstallID: session.agentInstallID,
                agentSessionID: remote.sessionId,
                protocolVersion: profile.protocolVersion,
                title: session.title,
                workingDirectory: session.workingDirectory,
                baseRevision: session.baseRevision,
                createdAt: session.createdAt
            )
            do {
                try await createSession(session)
            } catch {
                failure = failure ?? error
                throw error
            }
            guard status == .starting else { throw SessionError.invalidState }
            try await begin([try SessionEvent.started(configOptions: remote.configOptions).storedEvent()])
        } catch {
            if status == .closed, failure == nil { throw CancellationError() }
            throw await fail(error)
        }
    }

    /// Reattaches a saved session from `history(id:store:)` (ADR-0017). Writes nothing unless the agent accepts.
    public func reopen(connection: any ACP.AgentConnection, client: ACP.Implementation) async throws {
        guard status == .ready, let agentID = session.agentSessionID else { throw SessionError.invalidState }
        status = .starting
        self.connection = connection
        do {
            let profile = try await connection.initialize(client: client)
            guard status == .starting else { throw SessionError.invalidState }
            self.profile = profile
            guard additionalDirectories.isEmpty || profile.acceptsAdditionalDirectories else {
                throw SessionError.unsupportedAdditionalDirectories
            }
            let reopened = try await connection.reopenSession(
                agentID,
                cwd: session.workingDirectory,
                additionalDirectories: additionalDirectories,
                mcpServers: []
            )
            guard status == .starting else { throw SessionError.invalidState }
            let state: ACP.SessionState
            let method: SessionEvent.ReopenMethod
            switch reopened {
            case .resumed(let resumed): (state, method) = (resumed, .resume)
            case .loaded(let loaded): (state, method) = (loaded, .load)
            case .unavailable: throw SessionError.cannotReopen
            }
            // Close what an earlier run left open, so the new baseline starts with no turn or request pending.
            var events: [NewEvent] = []
            if let turn = reduced.activeTurn {
                events.append(
                    try SessionEvent.failed(id: turn, message: "Interrupted: Agenthesia stopped during this turn.")
                        .storedEvent()
                )
            }
            for id in reduced.unansweredPermissions {
                events.append(try SessionEvent.permissionResolved(id: id, outcome: .cancelled).storedEvent())
            }
            events.append(try SessionEvent.queuePaused(queuePaused).storedEvent())
            for id in reduced.unansweredInputs {
                events.append(try SessionEvent.inputResolved(id: id, response: .init(action: .cancel)).storedEvent())
            }
            events.append(try SessionEvent.reopened(configOptions: state.configOptions, method: method).storedEvent())
            try await begin(events)
        } catch {
            if status == .closed, failure == nil { throw CancellationError() }
            throw await fail(error)
        }
    }

    /// Enqueues the baseline and all early updates without yielding, before accepting live writes.
    private func begin(_ baseline: [NewEvent]) async throws {
        var events = baseline
        for (id, update, raw) in startupUpdates where id == session.agentSessionID {
            events += try updateEvents(update, raw: raw)
        }
        startupUpdates.removeAll()
        startupBytes = 0
        recording = true
        try await record(events)
        guard status == .starting else { throw SessionError.invalidState }
        status = .idle
        publishTranscript()
    }

    /// Reads history in bounded pages into a read-only controller. Does not contact the agent.
    public static func restore(id: UUID, store: PersistenceStore) async throws -> SessionController {
        let controller = try await history(id: id, store: store)
        controller.status = .readOnly
        controller.publishTranscript()
        return controller
    }

    /// Reads history in bounded pages into a controller that can `reopen` the session.
    public static func history(
        id: UUID,
        store: PersistenceStore,
        additionalDirectories: [String] = []
    ) async throws -> SessionController {
        guard let session = try await store.session(id: id) else { throw SessionError.sessionNotFound }
        let controller = SessionController(session: session, store: store, additionalDirectories: additionalDirectories)
        while true {
            let page = try await store.events(in: id, after: controller.reduced.sequence)
            guard !page.isEmpty else { break }
            for event in page { try controller.reduced.apply(event) }
        }
        controller.queuePaused = !controller.reduced.queuedPrompts.isEmpty || controller.reduced.queuePaused
        controller.publishTranscript()
        return controller
    }

    /// Changes settings only between turns. The agent's full response becomes visible after durable recording.
    /// Like a turn, accepted config work belongs to the controller rather than the waiting UI task.
    public func setConfigOption(_ id: ACP.ConfigOptionID, to value: ACP.ConfigValue) async throws {
        try Task.checkCancellation()
        guard status == .idle, !isChangingConfig, let connection, let agentID = session.agentSessionID else {
            throw SessionError.invalidState
        }
        isChangingConfig = true
        let task = Task {
            defer {
                isChangingConfig = false
                configTask = nil
            }
            try await connection.setConfigOption(id, to: value, in: agentID) { @MainActor options in
                // The adapter keeps this commit in wire order, ahead of later config notifications.
                guard self.status == .idle else { throw SessionError.invalidState }
                try await self.record([try SessionEvent.configOptions(options).storedEvent()])
                self.publishTranscript()
            }
        }
        configTask = task
        try await task.value
    }

    /// Accepts a composed message without making the caller own the wire turn.
    public func submit(_ content: [ACP.ContentBlock], intent: SubmissionIntent = .whenReady) async throws {
        try Task.checkCancellation()
        let intent = intent == .now && (try? Self.validate(content)) == nil ? .allNow : intent
        let generation = stopGeneration
        if intent != .allNow { try Self.validate(content) }
        try await coordinateQueue {
            guard [.idle, .running, .stopping].contains(self.status) else { throw SessionError.invalidState }
            if intent != .whenReady, self.stopGeneration != generation { throw SessionError.invalidState }
            if intent == .whenReady {
                let prompt = QueuedPrompt(content: content)
                if self.status == .idle, self.reduced.queuedPrompts.isEmpty, !self.queuePaused {
                    try await self.dispatch([prompt], removingQueued: false)
                } else {
                    try await self.record([
                        try SessionEvent.queueChanged(self.reduced.queuedPrompts + [prompt]).storedEvent()
                    ])
                    self.publishTranscript()
                }
                return
            }
            let draft = (try? Self.validate(content)) != nil ? QueuedPrompt(content: content) : nil
            var prompts = intent == .allNow ? self.reduced.queuedPrompts : []
            if let draft { prompts.append(draft) }
            guard !prompts.isEmpty else { throw SessionError.emptyPrompt }
            self.steering = true
            defer { self.steering = false }
            if self.status == .running, self.promptStarted, self.profile?.steering == .inject,
                let connection = self.connection, let agentID = self.session.agentSessionID, let turnID = self.turnID
            {
                let task = Task {
                    // Keep the complete draft durable without claiming it was delivered or dequeuing anything.
                    try await self.record([try SessionEvent.injectionPrepared(prompts).storedEvent()])
                    guard self.stopGeneration == generation, self.status == .running else { throw CancellationError() }
                    guard self.turnID == turnID, self.promptStarted else { return false }
                    try await connection.inject(prompts.flatMap(\.content), in: agentID)
                    try await self.record(
                        self.promptEvents(prompts, turnID: turnID, startsTurn: false, removingQueued: true)
                    )
                    return true
                }
                self.injectionTask = task
                let inserted: Bool
                do { inserted = try await task.value } catch {
                    self.injectionTask = nil
                    self.publishTranscript()
                    if error is CancellationError, self.stopGeneration != generation { return }
                    throw await self.fail(error)
                }
                self.injectionTask = nil
                self.publishTranscript()
                if inserted { return }
                // The prior wire turn ended while the preparation was committed. Send a fresh turn.
                try await self.waitForTurn()
                guard self.status == .idle, self.stopGeneration == generation else { throw SessionError.invalidState }
                try await self.dispatch(prompts, removingQueued: true)
                return
            }
            if self.status == .running { try await self.requestStop(interrupted: true) }
            try await self.waitForTurn()
            guard self.status == .idle, self.stopGeneration == generation else { throw SessionError.invalidState }
            if intent == .allNow {
                // Cancellation may have returned an earlier, not-yet-sent turn to the queue.
                prompts = self.reduced.queuedPrompts
                if let draft { prompts.append(draft) }
            }
            try await self.dispatch(prompts, removingQueued: intent == .allNow)
        }
    }

    /// Edits only the text, retaining all attachment blocks and the message identity.
    public func updateQueuedPrompt(_ id: UUID, text: String) async throws {
        try await changeQueue { prompts in
            guard let index = prompts.firstIndex(where: { $0.id == id }) else { throw SessionError.invalidState }
            let attachments = prompts[index].content.filter { if case .text = $0 { false } else { true } }
            let content: [ACP.ContentBlock] = text.isEmpty ? attachments : [.init(text: text)] + attachments
            try Self.validate(content)
            prompts[index].content = content
        }
    }

    public func removeQueuedPrompt(_ id: UUID) async throws {
        try await changeQueue { $0.removeAll { $0.id == id } }
    }

    public func moveQueuedPrompt(_ id: UUID, to destination: Int) async throws {
        try await changeQueue { prompts in
            guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
            let prompt = prompts.remove(at: index)
            prompts.insert(prompt, at: min(max(destination, 0), prompts.count))
        }
    }

    public func resumeQueue() async throws {
        let generation = stopGeneration
        try await coordinateQueue {
            guard self.stopGeneration == generation else { throw SessionError.invalidState }
            guard self.status == .idle || self.status == .running else { throw SessionError.invalidState }
            try await self.record([try SessionEvent.queuePaused(false).storedEvent()])
            guard self.stopGeneration == generation else { return }
            self.queuePaused = false
            self.publishTranscript()
            if self.status == .idle { try await self.drainQueue() }
        }
    }

    private func changeQueue(_ change: @escaping @MainActor (inout [QueuedPrompt]) throws -> Void) async throws {
        try await coordinateQueue {
            guard [.idle, .running, .stopping].contains(self.status) else { throw SessionError.invalidState }
            var prompts = self.reduced.queuedPrompts
            try change(&prompts)
            try await self.record([try SessionEvent.queueChanged(prompts).storedEvent()])
            self.publishTranscript()
        }
    }

    private func coordinateQueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = queueTask
        let task = Task {
            _ = await previous?.result
            // Lifecycle writes can arrive outside the queue coordinator; do not build a stale queue snapshot.
            while let pending = self.tail {
                try await pending.value
                if self.tail == pending { break }
            }
            try await operation()
        }
        queueTask = task
        try await task.value
    }

    private func promptEvents(
        _ prompts: [QueuedPrompt],
        turnID: UUID,
        startsTurn: Bool,
        removingQueued: Bool
    ) throws -> [NewEvent] {
        var events: [NewEvent] = []
        if removingQueued {
            let ids = Set(prompts.map(\.id))
            events.append(
                try SessionEvent.queueChanged(reduced.queuedPrompts.filter { !ids.contains($0.id) }).storedEvent()
            )
        }
        for (index, prompt) in prompts.enumerated() {
            events.append(
                try SessionEvent.promptMessage(
                    prompt: prompt,
                    turnID: turnID,
                    startsTurn: startsTurn && index == 0,
                    sentTogether: prompts.count > 1
                ).storedEvent()
            )
        }
        return events
    }

    private func dispatch(_ prompts: [QueuedPrompt], removingQueued: Bool) async throws {
        guard status == .idle, !isChangingConfig, let connection, let agentID = session.agentSessionID else {
            throw SessionError.invalidState
        }
        let id = UUID()
        let events = try promptEvents(prompts, turnID: id, startsTurn: true, removingQueued: removingQueued)
        let (_, committed) = startTurn(
            id: id,
            content: prompts.flatMap(\.content),
            events: events,
            connection: connection,
            agentID: agentID,
            unsentPrompts: prompts
        )
        do { try await committed.value } catch { throw await fail(error) }
        publishTranscript()
    }

    private func drainQueue() async throws {
        // A config change can enter while idle before a scheduled drain acquires the queue coordinator.
        // Wait for its confirmation rather than rejecting the drain and stranding an unpaused queue.
        _ = await configTask?.result
        guard status == .idle, !queuePaused, !steering, !reduced.queuedPrompts.isEmpty else { return }
        try await dispatch(reduced.queuedPrompts, removingQueued: true)
    }

    private static func validate(_ content: [ACP.ContentBlock]) throws {
        guard
            content.contains(where: {
                if case .text(let text) = $0 {
                    !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } else {
                    true
                }
            })
        else { throw SessionError.emptyPrompt }
    }

    /// Owns the turn task: cancelling a UI task waiting here cannot silently cancel the wire request.
    public func send(_ content: [ACP.ContentBlock]) async throws {
        try Task.checkCancellation()
        guard status == .idle, !isChangingConfig, let connection, let agentID = session.agentSessionID else {
            throw SessionError.invalidState
        }
        try Self.validate(content)
        let id = UUID()
        let event = try SessionEvent.prompt(id: id, content: content).storedEvent()
        let (task, _) = startTurn(id: id, content: content, events: [event], connection: connection, agentID: agentID)
        try await task.value
    }

    /// Steering can follow a rejected prompt on the same usable connection.
    private func waitForTurn() async throws {
        do { try await turnTask?.value } catch is RPCError where status == .idle && failure == nil {}
    }

    private func startTurn(
        id: UUID,
        content: [ACP.ContentBlock],
        events: [NewEvent],
        connection: any ACP.AgentConnection,
        agentID: ACP.SessionID,
        unsentPrompts: [QueuedPrompt] = []
    ) -> (Task<Void, any Error>, Task<Void, any Error>) {
        turnID = id
        status = .running
        let committed = enqueue(events)
        let task = Task {
            try await performTurn(
                id: id,
                content: content,
                connection: connection,
                agentID: agentID,
                committed: committed,
                unsentPrompts: unsentPrompts
            )
        }
        turnTask = task
        return (task, committed)
    }

    private func performTurn(
        id: UUID,
        content: [ACP.ContentBlock],
        connection: any ACP.AgentConnection,
        agentID: ACP.SessionID,
        committed: Task<Void, any Error>,
        unsentPrompts: [QueuedPrompt]
    ) async throws {
        var admitted = false
        var promptRejected = false
        defer {
            turnID = nil
            turnTask = nil
            stopTask = nil
            promptStarted = false
            // The agent ended the turn without waiting for an answer.
            cancelPermissions()
            cancelInputs()
            publishTranscript()
            if status == .idle, !queuePaused, !steering {
                Task { try? await self.coordinateQueue { try await self.drainQueue() } }
            }
        }
        do {
            try await committed.value
            guard status == .running || status == .stopping else { throw SessionError.invalidState }
            let reason: ACP.StopReason
            if status == .stopping {
                // Stop can arrive while the prompt is being committed, before anything reaches the agent.
                reason = .cancelled
            } else {
                promptStarted = true
                admitted = true
                do { reason = try await connection.prompt(content, in: agentID) } catch let error as RPCError {
                    promptRejected = true
                    throw error
                }
                promptStarted = false
            }
            do { _ = try await injectionTask?.value } catch {
                if !(error is CancellationError && status == .stopping) { throw error }
            }
            var events = [try SessionEvent.finished(id: id, reason: reason).storedEvent()]
            if !admitted, !unsentPrompts.isEmpty {
                events.append(try SessionEvent.promptsNotSent(turnID: id, prompts: unsentPrompts).storedEvent())
            }
            if !queuePaused, reason == .refusal || (reason == .cancelled && !steering) {
                queuePaused = true
                events.append(try SessionEvent.queuePaused(true).storedEvent())
            }
            try await record(events)
            // A delayed cancel must reach the connection before a subsequent prompt is allowed.
            try await stopTask?.value
            if reason != .cancelled { completedTurns += 1 }
            if status == .running || status == .stopping { status = .idle }
        } catch {
            promptStarted = false
            if promptRejected, status == .running || status == .stopping {
                queuePaused = true
                cancelPermissions()
                cancelInputs()
                do {
                    try await record([
                        try SessionEvent.queuePaused(true).storedEvent(),
                        try SessionEvent.failed(id: id, message: String(describing: error)).storedEvent(),
                    ])
                    do { _ = try await injectionTask?.value } catch {
                        if !(error is CancellationError && status == .stopping) { throw error }
                    }
                    // An admitted cancel must settle before steering can start another prompt.
                    try await stopTask?.value
                } catch { throw await fail(error) }
                if status == .running || status == .stopping {
                    status = .idle
                    throw error
                }
            }
            if status == .closed, failure == nil {
                // Deliberate close is a cancellation, not an agent failure.
                var events = [try SessionEvent.finished(id: id, reason: .cancelled).storedEvent()]
                if !admitted, !unsentPrompts.isEmpty {
                    events.append(try SessionEvent.promptsNotSent(turnID: id, prompts: unsentPrompts).storedEvent())
                }
                try await record(events)
                throw CancellationError()
            }
            if status != .failed {
                try? await record([
                    try SessionEvent.queuePaused(true).storedEvent(),
                    try SessionEvent.failed(id: id, message: String(describing: error)).storedEvent(),
                ])
            }
            throw await fail(error)
        }
    }

    /// Requests cancellation, but keeps recording updates until the prompt response arrives.
    public func stop() async throws {
        cancelInputs()
        guard [.idle, .running, .stopping].contains(status) else { return }
        stopGeneration += 1
        queuePaused = true
        let paused = enqueue([try SessionEvent.queuePaused(true).storedEvent()])
        // Reserve stopping synchronously; turn completion cannot slip an automatic drain past Stop.
        if status == .running { try await requestStop(interrupted: false) }
        do { try await paused.value } catch { throw await fail(error) }
        publishTranscript()
    }

    private func requestStop(interrupted: Bool) async throws {
        cancelInputs()
        guard status == .running, let id = turnID, let connection, let agentID = session.agentSessionID else { return }
        var events = [try SessionEvent.stopRequested(id: id).storedEvent()]
        if interrupted { events.append(try SessionEvent.interrupted(id: id).storedEvent()) }
        status = .stopping
        let committed = enqueue(events)
        // ACP: after session/cancel, every pending request is answered with `cancelled`.
        cancelPermissions()
        let task = Task {
            do {
                try await committed.value
                if turnID == id, status == .stopping, promptStarted { try await connection.cancel(agentID) }
            } catch {
                throw await fail(error)
            }
        }
        stopTask = task
        try await task.value
    }

    public func close() async {
        guard status != .closed else {
            await waitForInputs()
            _ = try? await configTask?.value
            _ = try? await turnTask?.value
            _ = try? await injectionTask?.value
            _ = try? await queueTask?.value
            _ = try? await tail?.value
            await fileSystem?.close()
            return
        }
        status = .closed
        fileSystem?.stopAccepting()
        cancelPermissions()
        cancelInputs()
        await connection?.close()
        await fileSystem?.close()
        _ = try? await configTask?.value
        _ = try? await turnTask?.value
        _ = try? await injectionTask?.value
        _ = try? await queueTask?.value
        _ = try? await tail?.value
        await waitForInputs()
        connection = nil
        publishTranscript()
    }

    /// Publishes all committed changes in one observable assignment. No-op on frames with no changes.
    public func publishTranscript() {
        guard transcript.sequence != reduced.sequence else { return }
        transcript = reduced
        if title != reduced.title { title = reduced.title }
    }

    @MainActor public func sessionUpdate(_ update: ACP.SessionUpdate, in sessionId: ACP.SessionID) async {
        // Re-encoding would silently discard unknown fields; a recording client requires a lossless adapter.
        if status == .starting || sessionId == session.agentSessionID {
            await fail(SessionError.missingRawNotification)
        }
    }

    @MainActor public func sessionUpdate(
        _ update: ACP.SessionUpdate,
        in sessionId: ACP.SessionID,
        rawNotification: Data
    ) async {
        guard status != .failed, status != .closed, status != .readOnly else { return }
        if status == .starting, !recording {
            guard startupBytes + rawNotification.count <= 16 * 1024 * 1024 else {
                await fail(SessionError.startupBufferFull)
                return
            }
            startupUpdates.append((sessionId, update, rawNotification))
            startupBytes += rawNotification.count
            return
        }
        guard recording, sessionId == session.agentSessionID else { return }
        do { try await record(updateEvents(update, raw: rawNotification)) } catch { await fail(error) }
    }

    @MainActor public func requestPermission(
        for toolCall: ACP.ToolCallUpdate,
        options: [ACP.PermissionOption],
        in sessionId: ACP.SessionID
    ) async -> ACP.PermissionOutcome {
        guard recording, sessionId == session.agentSessionID, status == .running || status == .stopping else {
            return .cancelled
        }
        let id = UUID()
        // Turn completion can cancel a request while its initial write is still suspended.
        permissions[id] = Permission(options: options)
        do {
            try await record([
                try SessionEvent.permissionRequested(id: id, toolCall: toolCall, options: options).storedEvent()
            ])
        } catch {
            permissions.removeValue(forKey: id)
            return .cancelled
        }
        if status == .running, !Task.isCancelled, permissions[id]?.response == nil {
            pendingPermissions.append(PendingPermission(id: id, options: options))
            publishTranscript()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if permissions[id]?.response == nil {
                        permissions[id]?.waiter = continuation
                    } else {
                        continuation.resume()
                    }
                }
            } onCancel: {
                // The agent withdrew this request with `$/cancel_request`, or the connection closed.
                Task { @MainActor in self.cancelPermission(id) }
            }
        } else {
            cancelPermission(id)
        }
        // A cancellation may supersede a decision while it is committed. Respond only after the last write.
        while let committed = permissions[id]?.committed {
            do { try await committed.value } catch {
                await fail(error)
                break
            }
            guard permissions[id]?.committed == committed else { continue }
            if Task.isCancelled, case .selected = permissions[id]?.response {
                cancelPermission(id)
                continue
            }
            break
        }
        let response = permissions.removeValue(forKey: id)?.response
        publishTranscript()
        guard status != .failed, case .selected(let option) = response else { return .cancelled }
        return .selected(option)
    }

    /// Answers a pending request with one of its offered options. Returns `false` for stale or repeated answers.
    @discardableResult public func answerPermission(_ id: UUID, with option: ACP.PermissionOptionID) -> Bool {
        guard status == .running, let permission = permissions[id], permission.response == nil,
            permission.options.contains(where: { $0.optionId == option })
        else { return false }
        resolvePermission(id, .selected(option))
        return true
    }

    /// Settles a request with `cancelled`. Supersedes a decision that has not been returned yet.
    private func cancelPermission(_ id: UUID) {
        guard let permission = permissions[id], permission.response != .cancelled else { return }
        resolvePermission(id, .cancelled)
    }

    private func cancelPermissions() {
        for id in permissions.keys { cancelPermission(id) }
    }

    /// Enqueues the outcome synchronously, so closing waits for it and later writes are ordered after it.
    private func resolvePermission(_ id: UUID, _ outcome: ACP.PermissionOutcome) {
        permissions[id]?.response = outcome
        if status != .failed, let event = try? SessionEvent.permissionResolved(id: id, outcome: outcome).storedEvent() {
            permissions[id]?.committed = enqueue([event])
        }
        permissions[id]?.waiter?.resume()
        permissions[id]?.waiter = nil
        pendingPermissions.removeAll { $0.id == id }
    }

    private struct Permission {
        let options: [ACP.PermissionOption]
        var response: ACP.PermissionOutcome?
        var waiter: CheckedContinuation<Void, Never>?
        /// The latest resolution write.
        var committed: Task<Void, any Error>?
    }

    /// Handles forms belonging to this established session; request-scoped startup input is declined (#111).
    @MainActor public func requestInput(_ request: ACP.ElicitationRequest) async -> ACP.ElicitationResponse {
        guard case .session(let sessionID, _) = request.scope else { return .init(action: .decline) }
        guard recording,
            sessionID == session.agentSessionID, case .form = request.mode,
            status == .running || status == .idle
        else { return .init(action: .cancel) }
        let id = UUID()
        let generation = inputGeneration
        // Register before yielding to persistence so close can cancel and drain this admitted caller.
        inputs[id] = Input(request: request)
        defer {
            inputs.removeValue(forKey: id)
            if inputs.isEmpty {
                for waiter in inputCloseWaiters { waiter.resume() }
                inputCloseWaiters.removeAll()
            }
        }
        do { try await record([try SessionEvent.inputRequested(id: id, request: request).storedEvent()]) } catch {
            return .init(action: .cancel)
        }
        if generation == inputGeneration, (status == .running || status == .idle), !Task.isCancelled {
            pendingInputs.append(PendingInput(id: id, request: request))
            publishTranscript()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if inputs[id]?.response == nil { inputs[id]?.waiter = continuation } else { continuation.resume() }
                }
            } onCancel: {
                Task { @MainActor in self.cancelInput(id) }
            }
        } else {
            cancelInput(id)
        }
        while let committed = inputs[id]?.committed {
            do { try await committed.value } catch { await fail(error); break }
            guard inputs[id]?.committed == committed else { continue }
            if Task.isCancelled, inputs[id]?.response?.action != .cancel { cancelInput(id); continue }
            break
        }
        let response = inputs[id]?.response
        publishTranscript()
        guard status != .failed else { return .init(action: .cancel) }
        return response ?? .init(action: .cancel)
    }

    /// Validates and commits the response before delivery. Stale or repeated answers return `false`.
    @discardableResult public func answerInput(_ id: UUID, with response: ACP.ElicitationResponse) -> Bool {
        guard status == .running || status == .idle, let input = inputs[id], input.response == nil,
            case .form(let schema) = input.request.mode
        else { return false }
        switch response.action {
        case .accept(let values):
            guard InputValidation.errors(in: values ?? [:], schema: schema).isEmpty else { return false }
        case .decline, .cancel: break
        case .unknown: return false
        }
        resolveInput(id, response)
        return true
    }

    private func cancelInput(_ id: UUID) {
        guard let input = inputs[id], input.response?.action != .cancel else { return }
        resolveInput(id, .init(action: .cancel))
    }

    private func waitForInputs() async {
        guard !inputs.isEmpty else { return }
        await withCheckedContinuation { inputCloseWaiters.append($0) }
    }

    private func cancelInputs() {
        inputGeneration &+= 1
        for id in inputs.keys { cancelInput(id) }
    }

    private func resolveInput(_ id: UUID, _ response: ACP.ElicitationResponse) {
        inputs[id]?.response = response
        if status != .failed, let event = try? SessionEvent.inputResolved(id: id, response: response).storedEvent() {
            inputs[id]?.committed = enqueue([event])
        }
        inputs[id]?.waiter?.resume()
        inputs[id]?.waiter = nil
        pendingInputs.removeAll { $0.id == id }
    }

    private struct Input {
        let request: ACP.ElicitationRequest
        var response: ACP.ElicitationResponse?
        var waiter: CheckedContinuation<Void, Never>?
        var committed: Task<Void, any Error>?
    }

    private func updateEvents(_ update: ACP.SessionUpdate, raw: Data) throws -> [NewEvent] {
        let original = try ACP.RecordedSessionUpdate(rawNotification: raw)
        guard original.sessionId == session.agentSessionID else { throw SessionError.invalidState }
        var events = [NewEvent(kind: SessionEvent.updateKind, payload: raw)]
        // Keep the wire payload intact and record adapter normalization explicitly for deterministic replay.
        if case .configOptions(let options) = update, update != original.update {
            events.append(try SessionEvent.configOptions(options.configOptions).storedEvent())
        }
        return events
    }

    private func enqueue(_ events: [NewEvent]) -> Task<Void, any Error> {
        // MainActor reentrancy does not serialize async writes. Capture and replace the tail BEFORE awaiting.
        let previous = tail
        let append = appendEvents
        let id = session.id
        let task = Task {
            try await previous?.value
            guard self.status != .failed else { throw SessionError.invalidState }
            let stored: [StoredEvent]
            do {
                stored = try await append(events, id)
            } catch {
                // A disk error racing with deliberate close must still reach the caller as a disk error.
                if self.failure == nil { self.failure = error }
                throw error
            }
            for event in stored { try self.reduced.apply(event) }
            if self.status == .failed || self.status == .closed { self.publishTranscript() }
        }
        tail = task
        return task
    }

    private func record(_ events: [NewEvent]) async throws {
        let task = enqueue(events)
        do { try await task.value } catch {
            throw await fail(error)
        }
    }

    /// Keep the first cause when closing the connection produces follow-up errors.
    @discardableResult private func fail(_ error: any Error) async -> any Error {
        guard status != .failed, status != .closed else { return failure ?? error }
        let cause = failure ?? error
        failure = cause
        queuePaused = true
        status = .failed
        fileSystem?.stopAccepting()
        cancelPermissions()
        cancelInputs()
        startupUpdates.removeAll()
        startupBytes = 0
        publishTranscript()
        await connection?.close()
        await fileSystem?.close()
        connection = nil
        return cause
    }
}
