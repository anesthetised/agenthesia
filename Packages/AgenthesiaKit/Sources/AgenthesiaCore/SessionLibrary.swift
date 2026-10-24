public import Foundation
public import Persistence

/// One database per app. Opening and migrations never block the main actor.
public actor SessionLibrary {
    public static let shared = SessionLibrary(
        databaseURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Agenthesia/history.sqlite")
    )
    private let databaseURL: URL
    private var opening: Task<PersistenceStore, any Error>?
    private var installing: Task<Void, Never>?

    public init(databaseURL: URL) { self.databaseURL = databaseURL }

    public func store() async throws -> PersistenceStore {
        if let opening { return try await opening.value }
        let url = databaseURL
        let task = Task.detached {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try PersistenceStore(databaseURL: url)
        }
        opening = task
        do { return try await task.value } catch { opening = nil; throw error }
    }

    public func projects() async throws -> [ProjectRecord] { try await store().projects() }

    public func history() async throws -> [SessionRecord] {
        let store = try await store()
        var result: [SessionRecord] = []
        for project in try await store.projects() {
            result += try await store.sessions(in: project.id)
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    /// Sessions whose worktree was merged or discarded; the outcome is always a session's last event (ADR-0032).
    public func worktreeOutcomes() async throws -> [UUID: WorktreeOutcome] {
        try await store().lastEvents().compactMapValues(WorktreeOutcome.init(lastEvent:))
    }

    /// Appends to a session without a live owner; the caller makes sure none writes to it meanwhile.
    func record(_ outcome: WorktreeOutcome, for sessionID: UUID) async throws {
        _ = try await store().append([SessionEvent.worktreeRemoved(outcome).storedEvent()], to: sessionID)
    }

    func project(id: UUID) async throws -> ProjectRecord? { try await store().projects().first { $0.id == id } }

    func install(id: UUID) async throws -> AgentInstallRecord? {
        try await store().agentInstalls().first { $0.id == id }
    }

    func project(directory: URL) async throws -> ProjectRecord {
        let store = try await store()
        if let existing = try await store.projects().first(where: { $0.rootPath == directory.path }) { return existing }
        let project = ProjectRecord(name: directory.lastPathComponent, rootPath: directory.path)
        do { try await store.createProject(project) } catch {
            // Another session may have inserted the same canonical directory during the write.
            if let existing = try await store.projects().first(where: { $0.rootPath == directory.path }) {
                return existing
            }
            throw error
        }
        return project
    }

    /// Lookups and inserts run one after another: parallel sessions often start with the same agent,
    /// and awaiting the store lets a second caller run between the lookup and the insert.
    func install(_ agent: AgentInstallRecord) async throws -> AgentInstallRecord {
        let previous = installing
        let task = Task {
            await previous?.value
            return try await insert(agent)
        }
        installing = Task { _ = try? await task.value }
        return try await task.value
    }

    private func insert(_ agent: AgentInstallRecord) async throws -> AgentInstallRecord {
        let store = try await store()
        if let existing = try await store.agentInstalls().first(where: {
            $0.executable == agent.executable && $0.arguments == agent.arguments
        }) {
            return existing
        }
        try await store.createAgentInstall(agent)
        return agent
    }
}
