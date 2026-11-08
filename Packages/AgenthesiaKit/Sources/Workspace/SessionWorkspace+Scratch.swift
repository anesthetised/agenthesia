public import Foundation

extension SessionWorkspace {
    /// Where sessions without a project get their folders (ADR-0048), next to the worktrees root.
    public static let defaultScratchRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".agenthesia/scratch")

    /// A session without a project (ADR-0048): a new, empty folder `<scratchRoot>/<words>-<8 hex digits>`, named like
    /// the session branch, that is both the project directory's child and the working directory. An existing folder
    /// fails rather than being shared. No Git, no base revision.
    public static func prepareScratch(
        id: UUID,
        topic: String? = nil,
        scratchRoot: URL = defaultScratchRoot
    ) async throws -> SessionWorkspace {
        try await blocking {
            try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
            let root = ScopedFileAccess.canonicalURL(scratchRoot)
            let folder = root.appending(path: readableName(for: id, topic: topic), directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists {
                throw WorkspaceError(message: "The folder “\(folder.path)” already exists.")
            }
            return SessionWorkspace(
                projectDirectory: root,
                workingDirectory: folder,
                baseRevision: nil,
                baseBranch: nil,
                branch: nil
            )
        }
    }

    /// The path the project of sessions without a project has as its root: the canonical `scratchRoot`.
    public static func scratchProjectPath(_ scratchRoot: URL = defaultScratchRoot) -> String {
        ScopedFileAccess.canonicalURL(scratchRoot).path
    }

    /// Removes the folder of a session without a project that never started, only while it is empty. Returns
    /// whether it was removed.
    @discardableResult public static func removeEmptyScratch(_ folder: URL) async throws -> Bool {
        try await blocking {
            guard try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty else { return false }
            try FileManager.default.removeItem(at: folder)
            return true
        }
    }
}
