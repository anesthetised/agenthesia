public import Foundation
import Observation
public import Persistence

/// The app's live sessions (ADR-0026). Windows select an owner; closing a window never ends a session.
@MainActor @Observable
public final class SessionManager {
    /// Owners in start order until End Session removes them; failed owners stay with their error.
    public private(set) var owners: [LiveSession] = []
    public let library: SessionLibrary
    /// What each window shows while it is key in the active app; those sessions need no notification.
    private var shown: [ObjectIdentifier: UUID] = [:]
    public var shownSessionIDs: Set<UUID> { Set(shown.values) }
    // Test seam applied to new owners; production uses the login-shell resolver.
    @ObservationIgnored var environment: (@Sendable () async -> (values: [String: String], diagnostic: String?))?

    public init(library: SessionLibrary = .shared) { self.library = library }

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
                worktreesRoot: worktreesRoot,
                additionalDirectories: additionalDirectories
            )
        )
    }

    /// The owner that has the session live, or a new one that continues it once earlier owners of the
    /// session have closed, so one owner writes to its log at a time (ADR-0017).
    public func resume(_ session: SessionRecord) -> LiveSession {
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

    private func add(_ launch: LiveSession.Launch, after previous: [LiveSession] = []) -> LiveSession {
        let owner = LiveSession(library: library)
        if let environment { owner.environment = environment }
        owners.append(owner)
        owner.begin(launch, after: previous)
        return owner
    }
}
