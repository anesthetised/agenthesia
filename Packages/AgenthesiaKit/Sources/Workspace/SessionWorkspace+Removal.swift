public import Foundation

extension SessionWorkspace {
    public static let defaultWorktreesRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".agenthesia/worktrees")

    /// A worktree Agenthesia created for one session. Only these are ever removed (ADR-0032).
    public struct Worktree: Equatable, Sendable {
        /// The checkout the worktree belongs to; Git runs here.
        public let projectDirectory: URL
        public let directory: URL
        public let branch: String

        /// Nil unless `workingDirectory` is `<worktreesRoot>/<project directory name>/<session id>` or inside it,
        /// as `prepare` creates it. Non-Git sessions and sessions in the user's own checkout never match.
        public init?(
            projectDirectory: URL,
            workingDirectory: URL,
            sessionID: UUID,
            worktreesRoot: URL = defaultWorktreesRoot
        ) {
            let slug = sessionID.uuidString.lowercased()
            let projectDirectory = projectDirectory.standardizedFileURL
            let expected = worktreesRoot.appending(path: projectDirectory.lastPathComponent).appending(path: slug)
                .resolvingSymlinksInPath().standardizedFileURL
            // The stored path was resolved at creation; resolving it again could follow a link planted since.
            let working = workingDirectory.standardizedFileURL.path
            guard projectDirectory.path != "/", !expected.path.hasPrefix(projectDirectory.path + "/"),
                working == expected.path || working.hasPrefix(expected.path + "/")
            else { return nil }
            self.projectDirectory = projectDirectory
            directory = expected
            branch = "agenthesia/\(slug)"
        }
    }

    /// What discarding would lose: uncommitted paths (untracked included) and commits on the session branch
    /// since `baseRevision`. A directory deleted by hand has no uncommitted paths.
    public static func discardSummary(
        of worktree: Worktree,
        baseRevision: String?
    ) async throws -> (uncommittedFiles: Int, commits: Int) {
        try await blocking {
            var uncommitted = 0
            if FileManager.default.fileExists(atPath: worktree.directory.path) {
                let status: Data = try gitOutput(
                    ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                    in: worktree.directory
                )
                var fields = status.split(separator: 0).makeIterator()
                while let field = fields.next() {
                    uncommitted += 1
                    // A rename or copy is followed by its source path.
                    if field.prefix(2).contains(where: { $0 == UInt8(ascii: "R") || $0 == UInt8(ascii: "C") }) {
                        _ = fields.next()
                    }
                }
            }
            var commits = 0
            if let baseRevision, hasBranch(worktree) {
                commits =
                    Int(
                        try git(
                            ["rev-list", "--count", "\(baseRevision)..refs/heads/\(worktree.branch)"],
                            in: worktree.projectDirectory
                        )
                    ) ?? 0
            }
            return (uncommitted, commits)
        }
    }

    /// Removes the worktree and its branch; idempotent, so a failed attempt can be retried. A directory deleted
    /// by hand is pruned. An existing directory must be a listed worktree on this session's branch.
    public static func remove(_ worktree: Worktree) async throws {
        try await blocking {
            let project = worktree.projectDirectory
            if FileManager.default.fileExists(atPath: worktree.directory.path) {
                let listed: Data = try gitOutput(["worktree", "list", "--porcelain", "-z"], in: project)
                let paths = listed.split(separator: 0).compactMap { field -> String? in
                    let line = String(decoding: field, as: UTF8.self)
                    return line.hasPrefix("worktree ") ? String(line.dropFirst("worktree ".count)) : nil
                }
                guard
                    paths.contains(where: {
                        URL(filePath: $0).resolvingSymlinksInPath().standardizedFileURL.path == worktree.directory.path
                    })
                else {
                    throw WorkspaceError(
                        message:
                            "“\(worktree.directory.path)” is not a worktree of “\(project.path)”; it was left in place."
                    )
                }
                // Refuse detached HEAD and any failure to verify the branch, as well as another named branch.
                guard
                    (try? git(["symbolic-ref", "--quiet", "HEAD"], in: worktree.directory))
                        == "refs/heads/\(worktree.branch)"
                else {
                    throw WorkspaceError(
                        message: "The worktree is no longer on “\(worktree.branch)”. It was left in place."
                    )
                }
                try git(["worktree", "remove", "--force", worktree.directory.path], in: project)
            } else {
                try git(["worktree", "prune"], in: project)
            }
            if hasBranch(worktree) {
                try git(["branch", "-D", worktree.branch], in: project)
            }
        }
    }

    private static func hasBranch(_ worktree: Worktree) -> Bool {
        (try? git(["rev-parse", "--verify", "--quiet", "refs/heads/\(worktree.branch)"], in: worktree.projectDirectory))
            != nil
    }

    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }
}
