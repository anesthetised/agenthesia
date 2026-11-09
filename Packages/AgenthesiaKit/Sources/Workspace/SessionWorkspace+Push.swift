public import Foundation

extension SessionWorkspace {
    /// The remote a merge can push `baseBranch` to (ADR-0045): its upstream's, nil when it tracks nothing or a local
    /// branch.
    public static func pushRemote(of baseBranch: String, in project: URL) async -> String? {
        try? await blocking {
            guard let upstream = upstream(of: baseBranch, in: project), upstream.remote != "." else { return nil }
            return upstream.remote
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
            var environment = environment ?? ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            let process = gitProcess(
                ["push", upstream.remote, "refs/heads/\(baseBranch):\(upstream.remoteBranch)"],
                in: project,
                environment: environment
            )
            // A file, not a pipe: an ssh child that outlives Git could hold a pipe open.
            let outputURL = FileManager.default.temporaryDirectory.appending(
                path: "agenthesia-push-\(UUID().uuidString)"
            )
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
            guard finished else {
                throw WorkspaceError(message: "The push did not finish in time and was stopped.\n\n\(text)")
            }
            guard process.terminationStatus == 0 else { throw WorkspaceError(message: text) }
        }
    }
}
