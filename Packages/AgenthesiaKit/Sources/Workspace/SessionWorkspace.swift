public import Foundation

/// A session's working directory. Worktrees are deliberately retained on close and failed startup.
public struct SessionWorkspace: Sendable {
    public let projectDirectory: URL
    public let workingDirectory: URL
    /// The actual new worktree's initial HEAD, before the agent starts; nil outside Git.
    public let baseRevision: String?

    public static func prepare(
        directory: URL,
        id: UUID,
        worktreesRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".agenthesia/worktrees")
    ) async throws -> SessionWorkspace {
        // Git can run for seconds on large checkouts; keep the blocking calls off the cooperative pool.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result { try prepareBlocking(directory: directory, id: id, worktreesRoot: worktreesRoot) }
                )
            }
        }
    }

    private static func prepareBlocking(directory: URL, id: UUID, worktreesRoot: URL) throws -> SessionWorkspace {
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
            return SessionWorkspace(projectDirectory: directory, workingDirectory: directory, baseRevision: nil)
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
        try git(["worktree", "add", "--quiet", "-b", "agenthesia/\(slug)", destination.path, "HEAD"], in: root)
        let worktree = destination.resolvingSymlinksInPath().standardizedFileURL
        let working = (prefix.isEmpty ? worktree : worktree.appending(path: prefix))
            .resolvingSymlinksInPath().standardizedFileURL
        guard working.path == worktree.path || working.path.hasPrefix(worktree.path + "/") else {
            throw WorkspaceError(message: "The selected directory resolves outside the session worktree at HEAD.")
        }
        guard (try? working.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw WorkspaceError(message: "The selected path is not a committed directory at HEAD.")
        }
        return SessionWorkspace(
            projectDirectory: root,
            workingDirectory: working,
            baseRevision: try git(["rev-parse", "--verify", "HEAD"], in: worktree)
        )
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
    @discardableResult static func git(_ arguments: [String], in directory: URL) throws -> String {
        String(decoding: try gitOutput(arguments, in: directory), as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    static func gitOutput(_ arguments: [String], in directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
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
}
