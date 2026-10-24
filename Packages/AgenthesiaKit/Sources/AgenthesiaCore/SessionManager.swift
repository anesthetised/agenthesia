import AgentRuntime
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
    /// Sessions being merged into their base branch; turns, Continue and discard are refused, and quit waits.
    private var merging: [UUID: Task<String, any Error>] = [:]
    // Test seam applied to new owners and merges; production uses the login-shell resolver.
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
        guard !isDiscarding(session.id), !isMerging(session.id) else { return nil }
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

    /// Closes every owner, including those still starting, before the app terminates. A merge finishes first,
    /// so the checkout is never left halfway through it.
    public func closeAll() async {
        for merge in merging.values { _ = await merge.result }
        await withTaskGroup(of: Void.self) { group in
            for owner in owners { group.addTask { await owner.close() } }
        }
    }

    public func isDiscarding(_ id: UUID) -> Bool { discarding[id] != nil }
    public var discardingIDs: Set<UUID> { Set(discarding.keys) }

    /// Whether the session has a worktree Agenthesia created and nothing blocks discarding or merging it now.
    /// Callers check the recorded outcome (`SessionLibrary.worktreeOutcomes`) themselves.
    public func canDiscard(_ session: SessionRecord, project: ProjectRecord?) -> Bool {
        guard let project, !isDiscarding(session.id), !isMerging(session.id), !isStarting(session.id) else {
            return false
        }
        return worktree(of: session, project: project) != nil
    }

    /// What discarding would lose, for the confirmation.
    public struct DiscardSummary: Equatable, Sendable {
        public let uncommittedFiles: Int
        public let commits: Int
        public let branch: String
    }

    public enum DiscardError: LocalizedError, Equatable {
        case notRemovable, starting, alreadyRemoved, merging

        public var errorDescription: String? {
            switch self {
            case .notRemovable: "This session has no worktree created by Agenthesia, so nothing was removed."
            case .starting: "The session is starting. Try again once it has started."
            case .alreadyRemoved: "The worktree of this session was already removed."
            case .merging: "The session is being merged. Try again once the merge has finished."
            }
        }
    }

    public func discardSummary(_ session: SessionRecord) async throws -> DiscardSummary {
        let (worktree, _) = try await removableWorktree(session)
        let counts = try await SessionWorkspace.discardSummary(of: worktree, baseRevision: session.baseRevision)
        return DiscardSummary(
            uncommittedFiles: counts.uncommittedFiles,
            commits: counts.commits,
            branch: worktree.branch
        )
    }

    /// Ends the session's owners, removes its worktree and branch, then records the outcome (ADR-0032).
    /// Nothing is recorded when Git fails, so a retry starts over. Concurrent calls share the first.
    /// After a merge whose removal failed, it finishes the removal and keeps the merge as the outcome.
    public func discard(_ session: SessionRecord) async throws {
        if let running = discarding[session.id] { return try await running.value }
        guard !isStarting(session.id) else { throw DiscardError.starting }
        guard !isMerging(session.id) else { throw DiscardError.merging }
        let task = Task {
            let (worktree, outcome) = try await removableWorktree(session)
            for owner in owners where owner.sessionID == session.id { await end(owner) }
            try await SessionWorkspace.remove(worktree)
            if outcome == nil { try await library.record(.discarded, for: session.id) }
        }
        discarding[session.id] = task
        defer { discarding[session.id] = nil }
        try await task.value
    }

    public func isMerging(_ id: UUID) -> Bool { merging[id] != nil }
    public var mergingIDs: Set<UUID> { Set(merging.keys) }

    public enum MergeCheck: Equatable, Sendable {
        /// Files changed from the merge base, uncommitted ones included, and the commits on the session branch.
        case ready(baseBranch: String, files: Int, commits: Int)
        case blocked(String)
    }

    public enum MergeError: LocalizedError, Equatable {
        case busy
        case blocked(String)
        /// Conflicting paths, relative to the project root.
        case conflicts([String])
        /// Git's output, for example from a rejecting hook.
        case failed(String)
        /// The commit exists and is recorded, but the worktree is still there; Discard Worktree… removes it.
        case worktreeKept(commit: String, reason: String)

        static let busyExplanation =
            "The session is working, starting, or being merged or discarded. Merge once it is idle, with no "
            + "queued prompts waiting to be sent."

        public var errorDescription: String? {
            switch self {
            case .busy: Self.busyExplanation
            case .blocked(let explanation): explanation
            case .conflicts(let paths):
                "The session’s changes conflict with the base branch in \(paths.count == 1 ? "1 file" : "\(paths.count) files"). "
                    + "The project checkout was left as it was."
            case .failed(let output): "Git stopped the merge, and the project checkout was left as it was.\n\n\(output)"
            case .worktreeKept(let commit, let reason):
                "Merged as \(commit.prefix(7)), but the worktree could not be removed. \(reason) "
                    + "Use Discard Worktree… to remove it."
            }
        }

        init(_ failure: SessionWorkspace.MergeFailure) {
            switch failure {
            case .blocked(let blocker): self = .blocked(blocker.explanation)
            case .conflicts(let paths): self = .conflicts(paths)
            case .failed(let output): self = .failed(output)
            }
        }
    }

    /// What blocks merging the session now, or what the merge would bring. Writes nothing.
    public func mergeCheck(_ session: SessionRecord) async throws -> MergeCheck {
        guard let base = session.baseBranch else {
            return .blocked(SessionWorkspace.MergeBlocker.noBaseBranch.explanation)
        }
        guard canBeginMerge(session.id) else { return .blocked(MergeError.busyExplanation) }
        let (worktree, outcome) = try await removableWorktree(session)
        guard outcome == nil else { throw DiscardError.alreadyRemoved }
        switch try await SessionWorkspace.mergeCheck(of: worktree, into: base) {
        case .ready(let files, let commits): return .ready(baseBranch: base, files: files, commits: commits)
        case .blocked(let blocker): return .blocked(blocker.explanation)
        }
    }

    /// Squash-merges the session into its base branch and returns the commit (ADR-0032). The agent stays attached
    /// until the commit exists, so it can resolve a conflict; then the owners end, the outcome is recorded and the
    /// worktree and branch are removed.
    @discardableResult public func merge(_ session: SessionRecord, message: String) async throws -> String {
        let id = session.id
        guard let base = session.baseBranch else {
            throw MergeError.blocked(SessionWorkspace.MergeBlocker.noBaseBranch.explanation)
        }
        let controller = owner(of: id)?.controller
        guard canBeginMerge(id), controller?.beginMerge() ?? true else { throw MergeError.busy }
        let task = Task {
            defer { controller?.endMerge() }
            let (worktree, outcome) = try await removableWorktree(session)
            guard outcome == nil else { throw DiscardError.alreadyRemoved }
            let resolve = environment ?? Self.shellEnvironment
            let commit: String
            do {
                commit = try await SessionWorkspace.merge(
                    worktree,
                    into: base,
                    message: message,
                    environment: await resolve().values
                )
            } catch let failure as SessionWorkspace.MergeFailure {
                throw MergeError(failure)
            }
            // Closing may still record events (a cancelled form), and the outcome must stay the last one.
            for owner in owners where owner.sessionID == id { await end(owner) }
            try await library.record(.merged(commit: commit, into: base), for: id)
            do { try await SessionWorkspace.remove(worktree) } catch {
                throw MergeError.worktreeKept(commit: commit, reason: error.localizedDescription)
            }
            return commit
        }
        merging[id] = task
        defer { merging[id] = nil }
        return try await task.value
    }

    /// Nothing else runs on the session, and its live owner, if any, is idle with no queued send pending.
    private func canBeginMerge(_ id: UUID) -> Bool {
        guard !isMerging(id), !isDiscarding(id), !isStarting(id) else { return false }
        return owner(of: id)?.controller?.canBeginMerge ?? true
    }

    private static let shellEnvironment: @Sendable () async -> (values: [String: String], diagnostic: String?) = {
        let resolution = await ShellEnvironment.shared.resolve()
        return (resolution.environment, resolution.diagnostic)
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

    /// The session's worktree and its recorded outcome. Only a merge whose removal failed leaves one behind.
    private func removableWorktree(
        _ session: SessionRecord
    ) async throws -> (SessionWorkspace.Worktree, WorktreeOutcome?) {
        guard let project = try await library.project(id: session.projectID),
            let worktree = worktree(of: session, project: project)
        else { throw DiscardError.notRemovable }
        let outcome = try await library.worktreeOutcomes()[session.id]
        switch outcome {
        case nil: break
        case .merged where FileManager.default.fileExists(atPath: worktree.directory.path): break
        default: throw DiscardError.alreadyRemoved
        }
        return (worktree, outcome)
    }

    private func add(_ launch: LiveSession.Launch, after previous: [LiveSession] = []) -> LiveSession {
        let owner = LiveSession(library: library)
        if let environment { owner.environment = environment }
        owners.append(owner)
        owner.begin(launch, after: previous)
        return owner
    }
}
