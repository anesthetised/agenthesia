public import Foundation
import Observation
public import Persistence
import Workspace

/// The app's live sessions (ADR-0026). Windows select an owner; closing a window never ends a session.
@MainActor @Observable
public final class SessionManager {
    /// Owners in start order until End Session removes them; failed owners stay with their error.
    public private(set) var owners: [LiveSession] = []
    public let library: SessionLibrary
    /// What each window shows while it is key in the active app; those sessions need no notification.
    private var shown: [ObjectIdentifier: UUID] = [:]
    public var shownSessionIDs: Set<UUID> { Set(shown.values) }
    /// Sessions whose worktree is being discarded; Continue and a second discard wait for or refuse them.
    private var discarding: [UUID: Task<Void, any Error>] = [:]
    // Test seam applied to new owners; production uses the login-shell resolver.
    @ObservationIgnored var environment: (@Sendable () async -> (values: [String: String], diagnostic: String?))?
    private let worktreesRoot: URL

    /// `worktreesRoot` defaults to `~/.agenthesia/worktrees`.
    public init(library: SessionLibrary = .shared, worktreesRoot: URL? = nil) {
        self.library = library
        self.worktreesRoot = worktreesRoot ?? SessionWorkspace.defaultWorktreesRoot
    }

    /// Adds an owner that starts in the background.
    public func start(
        directory: URL,
        agent: AgentInstallRecord,
        worktreesRoot: URL? = nil,
        additionalDirectories: [URL] = []
    ) -> LiveSession {
        add(
            .new(
                directory: directory,
                agent: agent,
                worktreesRoot: worktreesRoot ?? self.worktreesRoot,
                additionalDirectories: additionalDirectories
            )
        )
    }

    /// The owner that has the session live, or a new one that continues it once earlier owners of the
    /// session have closed, so one owner writes to its log at a time (ADR-0017). Nil while its worktree is
    /// being discarded.
    @discardableResult public func resume(_ session: SessionRecord) -> LiveSession? {
        guard !isDiscarding(session.id) else { return nil }
        if let live = owner(of: session.id) { return live }
        let previous = owners.filter { $0.sessionID == session.id }
        owners.removeAll { $0.sessionID == session.id }
        return add(.saved(session), after: previous)
    }

    public func owner(of id: UUID) -> LiveSession? { owners.first { $0.isLive && $0.sessionID == id } }

    /// Records the session a window shows in the key window of the active app, or `nil` once it does not.
    public func setShown(_ sessionID: UUID?, in window: AnyObject) {
        shown[ObjectIdentifier(window)] = sessionID
    }

    /// Closes the owner and removes it; its session remains in saved history.
    public func end(_ owner: LiveSession) async {
        await owner.close()
        owners.removeAll { $0 === owner }
    }

    /// Closes every owner, including those still starting, before the app terminates.
    public func closeAll() async {
        await withTaskGroup(of: Void.self) { group in
            for owner in owners { group.addTask { await owner.close() } }
        }
    }

    public func isDiscarding(_ id: UUID) -> Bool { discarding[id] != nil }
    public var discardingIDs: Set<UUID> { Set(discarding.keys) }

    /// Whether the session has a worktree Agenthesia created and nothing blocks discarding it now.
    /// Callers check the recorded outcome (`SessionLibrary.worktreeOutcomes`) themselves.
    public func canDiscard(_ session: SessionRecord, project: ProjectRecord?) -> Bool {
        guard let project, !isDiscarding(session.id), !isStarting(session.id) else { return false }
        return worktree(of: session, project: project) != nil
    }

    /// What discarding would lose, for the confirmation.
    public struct DiscardSummary: Equatable, Sendable {
        public let uncommittedFiles: Int
        public let commits: Int
        public let branch: String
    }

    public enum DiscardError: LocalizedError, Equatable {
        case notRemovable, starting, alreadyRemoved

        public var errorDescription: String? {
            switch self {
            case .notRemovable: "This session has no worktree created by Agenthesia, so nothing was removed."
            case .starting: "The session is starting. Try again once it has started."
            case .alreadyRemoved: "The worktree of this session was already removed."
            }
        }
    }

    public func discardSummary(_ session: SessionRecord) async throws -> DiscardSummary {
        let worktree = try await removableWorktree(session)
        let counts = try await SessionWorkspace.discardSummary(of: worktree, baseRevision: session.baseRevision)
        return DiscardSummary(
            uncommittedFiles: counts.uncommittedFiles,
            commits: counts.commits,
            branch: worktree.branch
        )
    }

    /// Ends the session's owners, removes its worktree and branch, then records the outcome (ADR-0032).
    /// Nothing is recorded when Git fails, so a retry starts over. Concurrent calls share the first.
    public func discard(_ session: SessionRecord) async throws {
        if let running = discarding[session.id] { return try await running.value }
        guard !isStarting(session.id) else { throw DiscardError.starting }
        let task = Task {
            let worktree = try await removableWorktree(session)
            for owner in owners where owner.sessionID == session.id { await end(owner) }
            try await SessionWorkspace.remove(worktree)
            try await library.record(.discarded, for: session.id)
        }
        discarding[session.id] = task
        defer { discarding[session.id] = nil }
        try await task.value
    }

    /// Starting a new session or continuing a saved one.
    private func isStarting(_ id: UUID) -> Bool { owners.contains { $0.sessionID == id && $0.isStarting } }

    private func worktree(of session: SessionRecord, project: ProjectRecord) -> SessionWorkspace.Worktree? {
        SessionWorkspace.Worktree(
            projectDirectory: URL(filePath: project.rootPath, directoryHint: .isDirectory),
            workingDirectory: URL(filePath: session.workingDirectory, directoryHint: .isDirectory),
            sessionID: session.id,
            worktreesRoot: worktreesRoot
        )
    }

    private func removableWorktree(_ session: SessionRecord) async throws -> SessionWorkspace.Worktree {
        guard let project = try await library.project(id: session.projectID),
            let worktree = worktree(of: session, project: project)
        else { throw DiscardError.notRemovable }
        guard try await library.worktreeOutcomes()[session.id] == nil else { throw DiscardError.alreadyRemoved }
        return worktree
    }

    private func add(_ launch: LiveSession.Launch, after previous: [LiveSession] = []) -> LiveSession {
        let owner = LiveSession(library: library)
        if let environment { owner.environment = environment }
        owners.append(owner)
        owner.begin(launch, after: previous)
        return owner
    }
}
