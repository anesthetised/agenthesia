public import Foundation

/// A session's working directory. Worktrees are retained on close and failed startup, except one whose session
/// never got a history record (`removeUntouched`).
public struct SessionWorkspace: Sendable {
    public let projectDirectory: URL
    public let workingDirectory: URL
    /// The actual new worktree's initial HEAD, before the agent starts; nil outside Git.
    public let baseRevision: String?
    /// The branch checked out in the selected checkout when the worktree was created; nil for a detached `HEAD`
    /// or outside Git. Such a session cannot be merged back.
    public let baseBranch: String?
    /// The session branch the worktree was created on; nil outside Git.
    public let branch: String?
    /// The upstream of `baseBranch` that could not be fetched, e.g. `origin/main`, so the worktree started from the
    /// local `HEAD` instead (ADR-0047). Nil when it started from the upstream, or the branch has none.
    public let fallbackUpstream: String?

    /// `topic` names the branch (`branchName`): the first line of the initial prompt. When the checked-out branch
    /// has an upstream, the worktree starts from it, fetched with `environment` (the login shell's, so credentials
    /// apply) and stopped after `fetchTimeout` (ADR-0047). `onFetch` is told the upstream (`origin/main`) when the
    /// fetch starts, from a background thread.
    public static func prepare(
        directory: URL,
        id: UUID,
        topic: String? = nil,
        worktreesRoot: URL = defaultWorktreesRoot,
        environment: [String: String]? = nil,
        fetchTimeout: Duration = .seconds(20),
        onFetch: (@Sendable (String) -> Void)? = nil
    ) async throws -> SessionWorkspace {
        // Git can run for seconds on large checkouts; keep the blocking calls off the cooperative pool.
        try await blocking {
            try prepareBlocking(
                directory: directory,
                id: id,
                topic: topic,
                worktreesRoot: worktreesRoot,
                environment: environment,
                fetchTimeout: fetchTimeout,
                onFetch: onFetch
            )
        }
    }

    private static func prepareBlocking(
        directory: URL,
        id: UUID,
        topic: String?,
        worktreesRoot: URL,
        environment: [String: String]?,
        fetchTimeout: Duration,
        onFetch: (@Sendable (String) -> Void)?
    ) throws -> SessionWorkspace {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw WorkspaceError(message: "Choose an existing directory.")
        }
        // A broken repository must fail rather than silently fall back to running in the user's checkout.
        guard hasGitEntry(atOrAbove: directory) else {
            // Bare repositories cannot supply a working directory.
            if (try? git(["rev-parse", "--is-bare-repository"], in: directory)) == "true" {
                throw WorkspaceError(message: "Choose a working checkout, not a bare repository.")
            }
            return SessionWorkspace(
                projectDirectory: directory,
                workingDirectory: directory,
                baseRevision: nil,
                baseBranch: nil,
                branch: nil,
                fallbackUpstream: nil
            )
        }
        let root: URL
        do {
            root = URL(
                filePath: try git(["rev-parse", "--show-toplevel"], in: directory),
                directoryHint: .isDirectory
            ).resolvingSymlinksInPath()
        } catch { throw brokenRepository(error) }
        let slug = id.uuidString.lowercased()
        let destination = worktreesRoot.appending(path: root.lastPathComponent).appending(path: slug)
            .resolvingSymlinksInPath().standardizedFileURL
        guard root.path != "/", !destination.path.hasPrefix(root.path + "/") else {
            throw WorkspaceError(message: "The worktree location must be outside the selected repository.")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Keep the selected subdirectory, e.g. one package of a monorepo.
        let prefix = try git(["rev-parse", "--show-prefix"], in: directory)
        // A detached HEAD makes this exit non-zero; that only means there is no branch to merge back into.
        let branch = (try? git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)).flatMap {
            $0.isEmpty ? nil : $0
        }
        var sessionBranch = branchName(for: id, topic: topic)
        // A taken name (the user's branch, or one left by a deleted database) falls back to the full session id.
        if (try? git(["rev-parse", "--verify", "--quiet", "refs/heads/\(sessionBranch)"], in: root)) != nil {
            sessionBranch = legacyBranchName(for: id)
        }
        // Fresh code for the agent: the fetched upstream, or `HEAD` without one or when the fetch fails (ADR-0047).
        var start = (revision: "HEAD", name: "HEAD")
        var fallbackUpstream: String?
        if let branch, let upstream = upstream(of: branch, in: root) {
            onFetch?(upstream.name)
            if fetch(upstream, in: root, environment: environment, timeout: fetchTimeout),
                let commit = try? git(
                    ["rev-parse", "--verify", "--end-of-options", "\(upstream.ref)^{commit}"],
                    in: root
                )
            {
                start = (commit, upstream.name)
            } else {
                fallbackUpstream = upstream.name
            }
        }
        try git(["worktree", "add", "--quiet", "-b", sessionBranch, destination.path, start.revision], in: root)
        let worktree = destination.resolvingSymlinksInPath().standardizedFileURL
        let working = (prefix.isEmpty ? worktree : worktree.appending(path: prefix))
            .resolvingSymlinksInPath().standardizedFileURL
        guard working.path == worktree.path || working.path.hasPrefix(worktree.path + "/") else {
            throw WorkspaceError(
                message: "The selected directory resolves outside the session worktree at \(start.name)."
            )
        }
        guard (try? working.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw WorkspaceError(message: "The selected path is not a committed directory at \(start.name).")
        }
        return SessionWorkspace(
            projectDirectory: root,
            workingDirectory: working,
            baseRevision: try git(["rev-parse", "--verify", "HEAD"], in: worktree),
            baseBranch: branch,
            branch: sessionBranch,
            fallbackUpstream: fallbackUpstream
        )
    }

    /// What `prepare` would start a worktree from: the upstream of the branch checked out in `directory`
    /// (`origin/main`), the branch itself without one, or the short commit of a detached `HEAD`. Nil outside Git,
    /// where the session works in the directory itself.
    public static func worktreeBase(of directory: URL) async -> String? {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard hasGitEntry(atOrAbove: directory) else { return nil }
        if let branch = try? await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory), !branch.isEmpty {
            return (try? await blocking { upstream(of: branch, in: directory) })?.name ?? branch
        }
        return (try? await git(["rev-parse", "--short", "HEAD"], in: directory)) ?? "HEAD"
    }

    /// The main checkout and root of a linked worktree containing `directory`, or nil outside one.
    public static func linkedCheckout(of directory: URL) async -> (checkout: URL, worktree: URL)? {
        guard
            let output = try? await git(
                ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"],
                in: directory
            )
        else { return nil }
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count == 2 else { return nil }
        let common = URL(filePath: lines[1], directoryHint: .isDirectory).resolvingSymlinksInPath()
        guard common.lastPathComponent == ".git" else { return nil }
        let checkout = common.deletingLastPathComponent().standardizedFileURL
        let worktree = URL(filePath: lines[0], directoryHint: .isDirectory).resolvingSymlinksInPath()
            .standardizedFileURL
        return checkout.path == worktree.path ? nil : (checkout, worktree)
    }

    /// Whether `directory` (resolved) or an ancestor has a `.git` entry, as in linked worktrees and submodules.
    /// Dangling `.git` symlinks count: they are broken repositories, not plain folders.
    static func hasGitEntry(atOrAbove directory: URL) -> Bool {
        var ancestor = directory
        while true {
            if (try? FileManager.default.attributesOfItem(atPath: ancestor.appending(path: ".git").path)) != nil {
                return true
            }
            if ancestor.path == "/" { return false }
            ancestor.deleteLastPathComponent()
        }
    }

    /// Git reports a broken `.git` entry as "not a git repository"; name the actual problem.
    static func brokenRepository(_ error: any Error) -> WorkspaceError {
        WorkspaceError(message: "The .git entry here or in a parent folder is broken. \(error.localizedDescription)")
    }

    struct WorkspaceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Async callers (including tests) must not block a cooperative thread: a cold `/usr/bin/git` shim can take seconds.
    @discardableResult static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let data = try await gitOutput(arguments, in: directory)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// Cancellation skips an unstarted command and discards its result; an admitted subprocess finishes.
    static func gitOutput(_ arguments: [String], in directory: URL) async throws -> Data {
        try Task.checkCancellation()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try gitOutput(arguments, in: directory) as Data })
            }
        }
        try Task.checkCancellation()
        return data
    }

    /// Blocks the calling thread. stderr goes to a file so a full pipe cannot deadlock and output stays clean.
    @discardableResult static func git(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String]? = nil
    ) throws -> String {
        String(decoding: try gitOutput(arguments, in: directory, environment: environment), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    /// `environment` replaces the app's own, e.g. with the login shell's so hooks find their tools.
    static func gitOutput(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String]? = nil
    ) throws -> Data {
        let process = gitProcess(arguments, in: directory, environment: environment)
        let output = Pipe()
        let errorURL = FileManager.default.temporaryDirectory.appending(path: "agenthesia-git-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw WorkspaceError(message: "Git: cannot create a temporary file.")
        }
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw WorkspaceError(message: "Git: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return data
    }

    /// A Git process in `directory` that ignores the repository variables of the app's own environment.
    static func gitProcess(_ arguments: [String], in directory: URL, environment base: [String: String]?) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = base ?? ProcessInfo.processInfo.environment
        for key in [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        ] {
            environment.removeValue(forKey: key)
        }
        // Read-only scans must not refresh the index and trigger their own filesystem watcher.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        return process
    }
}
