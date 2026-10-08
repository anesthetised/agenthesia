public import ACP
public import Foundation
import Observation
public import Persistence

/// One live session. The caller owns the process and passes its connection using this controller as delegate.
/// Call `publishTranscript()` from the view's display link; terminal states always publish immediately.
@MainActor @Observable
public final class SessionController: ACP.AgentConnectionDelegate {
    public enum Status: Equatable, Sendable {
        case ready, starting, idle, running, stopping, readOnly, failed, closed
    }

    public enum SessionError: Error, Equatable {
        case invalidState
        case emptyPrompt
        case missingRawNotification
        case startupBufferFull
        case sessionNotFound
    }

    public private(set) var status: Status = .ready
    public private(set) var transcript = TranscriptState()
    public var errorMessage: String? { failure.map { String(describing: $0) } }
    public private(set) var session: SessionRecord
    public private(set) var profile: ACP.AgentProfile?

    private var failure: (any Error)?
    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private var connection: (any ACP.AgentConnection)?
    @ObservationIgnored private var reduced = TranscriptState()
    @ObservationIgnored private var tail: Task<Void, any Error>?
    @ObservationIgnored private var turnTask: Task<Void, any Error>?
    @ObservationIgnored private var stopTask: Task<Void, any Error>?
    @ObservationIgnored private var turnID: UUID?
    @ObservationIgnored private var promptStarted = false
    @ObservationIgnored private var recording = false
    @ObservationIgnored private var startupUpdates: [(ACP.SessionID, ACP.SessionUpdate, Data)] = []
    @ObservationIgnored private var startupBytes = 0
    // Internal seam for deterministic disk-failure and suspended-write tests; production uses the store.
    @ObservationIgnored var appendEvents: @Sendable ([NewEvent], UUID) async throws -> [StoredEvent]

    /// The project and agent install must already exist. The draft session is inserted after session/new succeeds.
    public init(session: SessionRecord, store: PersistenceStore) {
        self.session = session
        self.store = store
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
            let remote = try await connection.newSession(
                cwd: session.workingDirectory,
                additionalDirectories: [],
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
                createdAt: session.createdAt
            )
            do {
                try await store.createSession(session)
            } catch {
                failure = failure ?? error
                throw error
            }
            guard status == .starting else { throw SessionError.invalidState }
            // Enqueue the baseline and all early updates without yielding, before accepting live writes.
            var events = [try SessionEvent.started(configOptions: remote.configOptions).storedEvent()]
            for (id, update, raw) in startupUpdates where id == remote.sessionId {
                events += try updateEvents(update, raw: raw)
            }
            startupUpdates.removeAll()
            startupBytes = 0
            recording = true
            try await record(events)
            guard status == .starting else { throw SessionError.invalidState }
            status = .idle
            publishTranscript()
        } catch {
            if status == .closed, failure == nil { throw CancellationError() }
            throw await fail(error)
        }
    }

    /// Reads history in bounded pages. Does not contact or resume the agent (#25).
    public static func restore(id: UUID, store: PersistenceStore) async throws -> SessionController {
        guard let session = try await store.session(id: id) else { throw SessionError.sessionNotFound }
        let controller = SessionController(session: session, store: store)
        while true {
            let page = try await store.events(in: id, after: controller.reduced.sequence)
            guard !page.isEmpty else { break }
            for event in page { try controller.reduced.apply(event) }
        }
        controller.status = .readOnly
        controller.publishTranscript()
        return controller
    }

    /// Owns the turn task: cancelling a UI task waiting here cannot silently cancel the wire request.
    public func send(_ content: [ACP.ContentBlock]) async throws {
        try Task.checkCancellation()
        guard status == .idle, let connection, let agentID = session.agentSessionID else {
            throw SessionError.invalidState
        }
        guard !content.isEmpty,
            content.contains(where: {
                if case .text(let text) = $0 {
                    !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } else {
                    true
                }
            })
        else { throw SessionError.emptyPrompt }
        let id = UUID()
        let event = try SessionEvent.prompt(id: id, content: content).storedEvent()
        turnID = id
        status = .running
        let committed = enqueue([event])
        let task = Task {
            try await performTurn(
                id: id,
                content: content,
                connection: connection,
                agentID: agentID,
                committed: committed
            )
        }
        turnTask = task
        try await task.value
    }

    private func performTurn(
        id: UUID,
        content: [ACP.ContentBlock],
        connection: any ACP.AgentConnection,
        agentID: ACP.SessionID,
        committed: Task<Void, any Error>
    ) async throws {
        defer {
            turnID = nil
            turnTask = nil
            stopTask = nil
            promptStarted = false
            publishTranscript()
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
                reason = try await connection.prompt(content, in: agentID)
                promptStarted = false
            }
            try await record([try SessionEvent.finished(id: id, reason: reason).storedEvent()])
            // A delayed cancel must reach the connection before a subsequent prompt is allowed.
            try await stopTask?.value
            if status == .running || status == .stopping { status = .idle }
        } catch {
            promptStarted = false
            if status == .closed, failure == nil {
                // Deliberate close is a cancellation, not an agent failure.
                try await record([try SessionEvent.finished(id: id, reason: .cancelled).storedEvent()])
                throw CancellationError()
            }
            if status != .failed {
                try? await record([try SessionEvent.failed(id: id, message: String(describing: error)).storedEvent()])
            }
            throw await fail(error)
        }
    }

    /// Requests cancellation, but keeps recording updates until the prompt response arrives.
    public func stop() async throws {
        guard status == .running, let id = turnID, let connection, let agentID = session.agentSessionID else { return }
        let event = try SessionEvent.stopRequested(id: id).storedEvent()
        status = .stopping
        let committed = enqueue([event])
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
        guard status != .closed else { return }
        status = .closed
        await connection?.close()
        _ = try? await turnTask?.value
        _ = try? await tail?.value
        connection = nil
        publishTranscript()
    }

    /// Publishes all committed changes in one observable assignment. No-op on frames with no changes.
    public func publishTranscript() {
        guard transcript.sequence != reduced.sequence else { return }
        transcript = reduced
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
        // Approval UI is #21. Never grant a permission implicitly while the domain is being connected.
        guard recording, sessionId == session.agentSessionID, status == .running || status == .stopping else {
            return .cancelled
        }
        let outcome: ACP.PermissionOutcome =
            status == .running && !Task.isCancelled
            ? options.first(where: { $0.kind == .rejectOnce }).map { .selected($0.optionId) } ?? .cancelled
            : .cancelled
        do {
            try await record([try SessionEvent.permission(toolCall: toolCall, outcome: outcome).storedEvent()])
        } catch {
            await fail(error)
            return .cancelled
        }
        publishTranscript()
        // Stop may arrive while the decision is being committed. Record the actual response too.
        if outcome != .cancelled, status != .running || Task.isCancelled {
            if status != .failed, failure == nil {
                try? await record([try SessionEvent.permission(toolCall: toolCall, outcome: .cancelled).storedEvent()])
            }
            return .cancelled
        }
        return outcome
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
        status = .failed
        startupUpdates.removeAll()
        startupBytes = 0
        publishTranscript()
        await connection?.close()
        connection = nil
        return cause
    }
}
