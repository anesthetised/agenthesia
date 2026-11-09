public import Foundation
public import Persistence
import Workspace

extension SessionManager {
    /// What deleting a saved session takes with it besides its history, for the confirmation (ADR-0044).
    public enum DeleteSummary: Equatable, Sendable {
        case merged
        case discarded
        /// The worktree and branch go first; nil when Git could not count what they hold.
        case worktree(DiscardSummary?)
        /// A session without a project: its folder goes to the Trash (ADR-0048).
        case folder(name: String, files: Int)
        /// The session never stored an event.
        case failedToStart
        case history
    }

    public enum DeleteError: LocalizedError, Equatable {
        case live, busy

        public var errorDescription: String? {
            switch self {
            case .live: "End the session first."
            case .busy: "The session is being merged, discarded or deleted. Try again once that has finished."
            }
        }
    }

    public func deleteSummary(_ session: SessionRecord) async throws -> DeleteSummary {
        let (outcomes, activity) = try await library.lastEvents()
        switch outcomes[session.id] {
        case .merged: return .merged
        case .discarded: return .discarded
        case nil: break
        }
        guard let project = try await library.project(id: session.projectID) else {
            return activity[session.id] == nil ? .failedToStart : .history
        }
        if let folder = scratchFolder(of: session, project: project) {
            return .folder(name: folder.lastPathComponent, files: Self.fileCount(in: folder))
        }
        if let worktree = worktree(of: session, project: project),
            FileManager.default.fileExists(atPath: worktree.directory.path)
        {
            return .worktree(try? await discardSummary(session))
        }
        return activity[session.id] == nil ? .failedToStart : .history
    }

    /// Deletes a saved session for good (ADR-0044). Its files go first: a worktree Agenthesia created, under
    /// ADR-0032's checks, or the folder of a session without a project, to the Trash. When that fails nothing is
    /// deleted. Then its record and events go in one transaction. A live session is refused.
    public func delete(_ session: SessionRecord) async throws {
        let id = session.id
        guard owner(of: id) == nil, !owners.contains(where: { $0.sessionID == id && $0.isStarting }) else {
            throw DeleteError.live
        }
        guard !isDiscarding(id), !isMerging(id), !deletingIDs.contains(id) else { throw DeleteError.busy }
        deletingIDs.insert(id)
        defer { deletingIDs.remove(id) }
        if let project = try await library.project(id: session.projectID) {
            if let folder = scratchFolder(of: session, project: project) {
                if FileManager.default.fileExists(atPath: folder.path) { try trash(folder) }
            } else if let worktree = worktree(of: session, project: project) {
                let outcome = try await library.worktreeOutcomes()[id]
                let exists = FileManager.default.fileExists(atPath: worktree.directory.path)
                // A discarded or merged worktree is gone; a project removed by hand leaves nothing to run Git in.
                if exists || (outcome == nil && FileManager.default.fileExists(atPath: project.rootPath)) {
                    try await SessionWorkspace.remove(worktree)
                }
            }
        }
        for owner in owners where owner.sessionID == id { await end(owner) }
        try await library.store().deleteSession(id)
        deletedIDs.insert(id)
    }

    /// The folder of a session without a project, only when it lies directly in the scratch root: a stored path
    /// anywhere else is never touched (ADR-0048).
    func scratchFolder(of session: SessionRecord, project: ProjectRecord) -> URL? {
        guard project.isScratch(scratchPath: scratchPath) else { return nil }
        let folder = URL(filePath: session.workingDirectory, directoryHint: .isDirectory)
        guard folder.deletingLastPathComponent().path == scratchPath,
            !folder.pathComponents.contains(where: { $0 == "." || $0 == ".." })
        else { return nil }
        return folder
    }

    /// Regular files below `folder`, without following symbolic links.
    static func fileCount(in folder: URL) -> Int {
        guard
            let files = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        else { return 0 }
        return files.reduce(0) { count, item in
            let isFile = (item as? URL).flatMap { try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile }
            return count + (isFile == true ? 1 : 0)
        }
    }
}
