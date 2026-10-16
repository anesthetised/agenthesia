public import Foundation
import Workspace

/// Session file observation remains available for saved history and after the agent process exits.
@MainActor public final class SessionFileChanges {
    private let watcher: DirectoryWatcher

    public init(directory: URL, onChange: @escaping @MainActor @Sendable () -> Void) async throws {
        let roots = try await SessionWorkspace.watchDirectories(in: directory)
        try Task.checkCancellation()
        watcher = try DirectoryWatcher(directories: roots, onChange: onChange)
    }

    public static func paths(in directory: URL, baseRevision: String?) async throws -> [String] {
        try await SessionWorkspace.changedPaths(in: directory, baseRevision: baseRevision)
    }

    public static func isGitRepository(in directory: URL) async throws -> Bool {
        try await SessionWorkspace.repositoryRoot(in: directory) != nil
    }

    public func close() { watcher.close() }
}
