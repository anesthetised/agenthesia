public import Foundation

extension SessionWorkspace {
    /// Why a session cannot be merged now. Finding one writes nothing (ADR-0032).
    public enum MergeBlocker: Equatable, Sendable {
        case noBaseBranch
        case baseBranchMissing(String)
        case checkoutOnOtherBranch(base: String, current: String?)
        case checkoutHasChanges
        case worktreeUnavailable
        case unresolvedConflicts
        case nothingToMerge

        public var explanation: String {
            switch self {
            case .noBaseBranch:
                "The session started from a detached HEAD or before Agenthesia recorded branches, so it has no branch "
                    + "to merge into. It can only be discarded."
            case .baseBranchMissing(let base): "The base branch “\(base)” no longer exists."
            case .checkoutOnOtherBranch(let base, let current):
                "The project checkout is on \(current.map { "“\($0)”" } ?? "a detached HEAD"), not “\(base)”. "
                    + "Switch it to “\(base)” to merge."
            case .checkoutHasChanges:
                "The project checkout has uncommitted changes to tracked files. Commit or stash them to merge."
            case .worktreeUnavailable: "The session worktree is missing or no longer on its branch."
            case .unresolvedConflicts:
                "The session worktree has unresolved conflicts. Ask the agent to resolve them before merging."
            case .nothingToMerge: "The session has no changes to merge."
            }
        }
    }

    public enum MergeCheck: Equatable, Sendable {
        /// Files changed from the merge base, uncommitted and untracked ones included, and the session's commits.
        case ready(files: Int, commits: Int)
        case blocked(MergeBlocker)
    }

    public enum MergeFailure: Error, Equatable {
        case blocked(MergeBlocker)
        /// The squash conflicted and the checkout was restored. Paths are relative to the project root.
        case conflicts([String])
        /// Git refused the squash or the final commit, for example in a hook; the checkout was restored.
        case failed(String)
    }

    /// What blocks merging the session into `baseBranch`, or what the merge would bring. Read-only.
    public static func mergeCheck(of worktree: Worktree, into baseBranch: String?) async throws -> MergeCheck {
        guard let baseBranch else { return .blocked(.noBaseBranch) }
        return try await blocking { try check(worktree, baseBranch) }
    }

    /// Squash-merges the session branch with its uncommitted work into `baseBranch` in the project checkout and
    /// returns the new commit (ADR-0032). `environment` is used for the commits, so the user's hooks and signing
    /// find their tools. Any failure after the squash restores the checkout with `git reset --merge`.
    public static func merge(
        _ worktree: Worktree,
        into baseBranch: String?,
        message: String,
        environment: [String: String]? = nil
    ) async throws -> String {
        guard let baseBranch else { throw MergeFailure.blocked(.noBaseBranch) }
        return try await blocking {
            if case .blocked(let blocker) = try check(worktree, baseBranch) { throw MergeFailure.blocked(blocker) }
            let project = worktree.projectDirectory
            if !(try git(["status", "--porcelain", "--untracked-files=all"], in: worktree.directory)).isEmpty {
                try git(["add", "-A"], in: worktree.directory)
                // Squashed away below, so it skips hooks and signing.
                try git(
                    [
                        "-c", "commit.gpgSign=false", "commit", "--quiet", "--no-verify", "-m",
                        "Uncommitted session changes",
                    ],
                    in: worktree.directory,
                    environment: environment
                )
            }
            do {
                try git(["merge", "--squash", "--quiet", worktree.branch], in: project, environment: environment)
            } catch let error as WorkspaceError {
                let unmerged =
                    (try? gitOutput(["diff", "--name-only", "--diff-filter=U", "-z"], in: project)) ?? Data()
                try git(["reset", "--merge"], in: project)
                let conflicts = unmerged.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                throw conflicts.isEmpty ? MergeFailure.failed(error.message) : .conflicts(conflicts)
            }
            // The session's changes may already be on the base branch.
            if (try? git(["diff", "--cached", "--quiet"], in: project)) != nil {
                try git(["reset", "--merge"], in: project)
                throw MergeFailure.blocked(.nothingToMerge)
            }
            let file = FileManager.default.temporaryDirectory.appending(path: "agenthesia-merge-\(UUID().uuidString)")
            try message.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try git(["commit", "--quiet", "-F", file.path], in: project, environment: environment)
            } catch let error as WorkspaceError {
                try git(["reset", "--merge"], in: project)
                throw MergeFailure.failed(error.message)
            }
            return try git(["rev-parse", "HEAD"], in: project)
        }
    }

    private static func check(_ worktree: Worktree, _ base: String) throws -> MergeCheck {
        let project = worktree.projectDirectory
        let ref = "refs/heads/\(base)"
        let branch = "refs/heads/\(worktree.branch)"
        guard (try? git(["rev-parse", "--verify", "--quiet", "--end-of-options", ref], in: project)) != nil else {
            return .blocked(.baseBranchMissing(base))
        }
        let current = try? git(["symbolic-ref", "--quiet", "HEAD"], in: project)
        guard current == ref else {
            let name = current.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
            return .blocked(.checkoutOnOtherBranch(base: base, current: name))
        }
        guard try git(["status", "--porcelain", "--untracked-files=no"], in: project).isEmpty else {
            return .blocked(.checkoutHasChanges)
        }
        guard FileManager.default.fileExists(atPath: worktree.directory.path), try isRegistered(worktree),
            (try? git(["symbolic-ref", "--quiet", "HEAD"], in: worktree.directory)) == branch
        else { return .blocked(.worktreeUnavailable) }
        guard try git(["diff", "--name-only", "--diff-filter=U"], in: worktree.directory).isEmpty else {
            return .blocked(.unresolvedConflicts)
        }
        let mergeBase = try git(["merge-base", ref, branch], in: project)
        let changed = try gitOutput(["diff", "--name-only", "-z", "-M", mergeBase], in: worktree.directory)
        let untracked = try gitOutput(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree.directory)
        let files = changed.split(separator: 0).count + untracked.split(separator: 0).count
        guard files > 0 else { return .blocked(.nothingToMerge) }
        let commits = Int(try git(["rev-list", "--count", "\(ref)..\(branch)"], in: project)) ?? 0
        return .ready(files: files, commits: commits)
    }
}
