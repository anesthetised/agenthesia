public import Foundation

extension SessionWorkspace {
    /// The remote a merge can push `baseBranch` to (ADR-0045): its upstream's, nil when it tracks nothing or a local
    /// branch.
    public static func pushRemote(of baseBranch: String, in project: URL) async -> String? {
        await remoteUpstream(of: baseBranch, in: project)?.remote
    }

    /// A branch's upstream on a remote, nil when it tracks nothing or a local branch.
    public struct RemoteBranch: Equatable, Sendable {
        public let remote: String
        /// The branch's name on the remote, e.g. `main`.
        public let branch: String
        /// The short name shown to the user, e.g. `origin/main`.
        public let name: String
    }

    public static func remoteUpstream(of branch: String, in directory: URL) async -> RemoteBranch? {
        try? await blocking {
            guard let upstream = upstream(of: branch, in: directory), upstream.remote != "." else { return nil }
            let prefix = "refs/heads/"
            let name =
                upstream.remoteBranch.hasPrefix(prefix)
                ? String(upstream.remoteBranch.dropFirst(prefix.count)) : upstream.remoteBranch
            return RemoteBranch(remote: upstream.remote, branch: name, name: upstream.name)
        }
    }

    /// Pushes `baseBranch` to the branch its upstream names (ADR-0045). It never pulls, rebases or forces, so a
    /// remote that moved rejects it. Credentials cannot be asked for, and after `timeout` the push is stopped.
    /// Throws with Git's output.
    public static func push(
        _ baseBranch: String,
        in project: URL,
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(120)
    ) async throws {
        try await blocking {
            guard let upstream = upstream(of: baseBranch, in: project), upstream.remote != "." else {
                throw WorkspaceError(message: "“\(baseBranch)” has no upstream on a remote, so nothing was pushed.")
            }
            try runPush(
                ["push", upstream.remote, "refs/heads/\(baseBranch):\(upstream.remoteBranch)"],
                in: project,
                environment: environment,
                timeout: timeout
            )
        }
    }

    /// The message of the commit that takes a session's uncommitted changes along to the remote (ADR-0045).
    public static let uncommittedChangesMessage = "Agenthesia: uncommitted changes before push"

    /// Commits the worktree's uncommitted changes on the session branch, if it has any, without running hooks;
    /// whether it committed. Reviewers see this commit, so its message says what it is (ADR-0045).
    @discardableResult public static func commitUncommittedChanges(
        in worktree: URL,
        environment: [String: String]? = nil
    ) async throws -> Bool {
        try await blocking {
            guard !(try git(["status", "--porcelain", "--untracked-files=all"], in: worktree)).isEmpty else {
                return false
            }
            try git(["add", "-A"], in: worktree)
            try git(
                ["commit", "--quiet", "--no-verify", "-m", uncommittedChangesMessage],
                in: worktree,
                environment: environment
            )
            return true
        }
    }

    /// `git push -u <remote> <branch>` of a session branch (ADR-0045), like the base branch's push: never forced,
    /// without prompts, stopped after `timeout`. Throws with Git's output.
    public static func pushBranch(
        _ branch: String,
        to remote: String,
        in worktree: URL,
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(120)
    ) async throws {
        try await blocking {
            try runPush(["push", "-u", remote, branch], in: worktree, environment: environment, timeout: timeout)
        }
    }

    /// The worktree has uncommitted changes or commits its branch's upstream does not have; false without an
    /// upstream.
    public static func hasUnpushedWork(in worktree: URL) async -> Bool {
        (try? await blocking {
            guard try git(["status", "--porcelain", "--untracked-files=all"], in: worktree).isEmpty else {
                return true
            }
            return (Int(try git(["rev-list", "--count", "@{upstream}..HEAD"], in: worktree)) ?? 0) > 0
        }) ?? false
    }

    /// Blocks the calling thread.
    private static func runPush(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String]?,
        timeout: Duration
    ) throws {
        var environment = environment ?? ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let process = gitProcess(arguments, in: directory, environment: environment)
        try run(process, timeout: timeout, stopped: "The push did not finish in time and was stopped.")
    }

    /// Runs `process` with its output in a file, stopped after `timeout`, and returns the output; throws with it
    /// when the process fails or is stopped. Blocks the calling thread.
    @discardableResult static func run(_ process: Process, timeout: Duration, stopped: String) throws -> String {
        // A file, not a pipe: an ssh child that outlives Git could hold a pipe open.
        let outputURL = FileManager.default.temporaryDirectory.appending(path: "agenthesia-push-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw WorkspaceError(message: "Git: cannot create a temporary file.")
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let finished = exited.wait(timeout: .now() + timeout / .seconds(1)) == .success
        if !finished {
            process.terminate()
            exited.wait()
        }
        let text = String(decoding: (try? Data(contentsOf: outputURL)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard finished else { throw WorkspaceError(message: "\(stopped)\n\n\(text)") }
        guard process.terminationStatus == 0 else { throw WorkspaceError(message: text) }
        return text
    }
}
