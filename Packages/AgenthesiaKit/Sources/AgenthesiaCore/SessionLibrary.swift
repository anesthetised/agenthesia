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

    public func history() async throws -> [SessionRecord] {
        let store = try await store()
        var result: [SessionRecord] = []
        for project in try await store.projects() {
            result += try await store.sessions(in: project.id)
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    func project(directory: URL) async throws -> ProjectRecord {
        let store = try await store()
        if let existing = try await store.projects().first(where: { $0.rootPath == directory.path }) { return existing }
        let project = ProjectRecord(name: directory.lastPathComponent, rootPath: directory.path)
        do { try await store.createProject(project) } catch {
            // Another window may have inserted the same canonical directory during the write.
            if let existing = try await store.projects().first(where: { $0.rootPath == directory.path }) {
                return existing
            }
            throw error
        }
        return project
    }

    func install(_ agent: AgentInstallRecord) async throws -> AgentInstallRecord {
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
