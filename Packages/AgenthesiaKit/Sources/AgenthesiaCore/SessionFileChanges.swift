public import Foundation
public import Workspace

/// Session file observation remains available for saved history and after the agent process exits.
@MainActor public final class SessionFileChanges {
    private let watcher: DirectoryWatcher

    public init(directory: URL, onChange: @escaping @MainActor @Sendable () -> Void) async throws {
        let roots = try await SessionWorkspace.watchDirectories(in: directory)
        try Task.checkCancellation()
        // Object and reflog writes (e.g. by another worktree) matter only together with a ref or index change.
        let selected = directory.resolvingSymlinksInPath().standardizedFileURL
        // FSEvents matches exclusions against physical paths (e.g. /private/var).
        let metadata = ScopedFileAccess(roots: roots.filter { $0.standardizedFileURL != selected }).roots
        watcher = try DirectoryWatcher(
            directories: roots,
            excluding: metadata.flatMap { [$0.appending(path: "objects"), $0.appending(path: "logs")] },
            onChange: onChange
        )
    }

    public static func paths(in directory: URL, baseRevision: String?) async throws -> [String] {
        try await SessionWorkspace.changedPaths(in: directory, baseRevision: baseRevision)
    }

    public static func stats(in directory: URL, baseRevision: String?) async throws -> ChangeStats {
        try await SessionWorkspace.changeStats(in: directory, baseRevision: baseRevision)
    }

    public static func isGitRepository(in directory: URL) async throws -> Bool {
        try await SessionWorkspace.repositoryRoot(in: directory) != nil
    }

    public func close() { watcher.close() }
}
