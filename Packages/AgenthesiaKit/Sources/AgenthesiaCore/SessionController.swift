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

    /// A request awaiting the user's choice, oldest first. Its transcript row carries the tool context.
    public struct PendingPermission: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let options: [ACP.PermissionOption]
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
    /// Observed separately so window chrome does not re-render on every published transcript frame.
    public private(set) var title: String?
    public var errorMessage: String? { failure.map { String(describing: $0) } }
    public private(set) var session: SessionRecord
    public private(set) var profile: ACP.AgentProfile?
    public private(set) var pendingPermissions: [PendingPermission] = []

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
    @ObservationIgnored private var permissions: [UUID: Permission] = [:]
    // Internal seam for deterministic disk-failure and suspended-write tests; production uses the store.
    @ObservationIgnored var createSession: @Sendable (SessionRecord) async throws -> Void
    @ObservationIgnored var appendEvents: @Sendable ([NewEvent], UUID) async throws -> [StoredEvent]

    /// The project and agent install must already exist. The draft session is inserted after session/new succeeds.
    public init(session: SessionRecord, store: PersistenceStore) {
        self.session = session
        self.store = store
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
                try await createSession(session)
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
            // The agent ended the turn without waiting for an answer.
            cancelPermissions()
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
        guard status != .closed else { return }
        status = .closed
        cancelPermissions()
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
        do {
            try await record([
                try SessionEvent.permissionRequested(id: id, toolCall: toolCall, options: options).storedEvent()
            ])
        } catch {
            return .cancelled
        }
        permissions[id] = Permission(options: options)
        if status == .running, !Task.isCancelled {
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
        cancelPermissions()
        startupUpdates.removeAll()
        startupBytes = 0
        publishTranscript()
        await connection?.close()
        connection = nil
        return cause
    }
}
