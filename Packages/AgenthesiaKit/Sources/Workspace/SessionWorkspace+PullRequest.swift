public import Foundation

extension SessionWorkspace {
    /// Whether the GitHub CLI is on the environment's `PATH` and signed in (`gh auth status`), which Open Pull
    /// Request… needs (ADR-0045). False when it is missing, signed out or does not answer within `timeout`.
    public static func gitHubCLIIsSignedIn(
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return
            (try? await blocking {
                try run(gh(["auth", "status"], in: home, environment: environment), timeout: timeout, stopped: "")
            }) != nil
    }

    /// `gh pr create` from `head` into `base`; the pull request's address and number, from the URL `gh` prints.
    /// Throws with `gh`'s output, also when it printed no pull request URL.
    public static func createPullRequest(
        base: String,
        head: String,
        title: String,
        body: String,
        in worktree: URL,
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(120)
    ) async throws -> (url: URL, number: Int) {
        let output = try await blocking {
            let process = gh(
                ["pr", "create", "--base", base, "--head", head, "--title", title, "--body", body],
                in: worktree,
                environment: environment
            )
            return try run(process, timeout: timeout, stopped: "gh did not finish in time and was stopped.")
        }
        guard let created = pullRequest(in: output) else {
            throw WorkspaceError(message: "gh printed no pull request address.\n\n\(output)")
        }
        return created
    }

    /// The last `https` line of `gh pr create`'s output whose last path component is the pull request's number.
    static func pullRequest(in output: String) -> (url: URL, number: Int)? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let url = URL(string: text), url.scheme == "https", let number = Int(url.lastPathComponent) {
                return (url, number)
            }
        }
        return nil
    }

    /// `gh` found through the environment's `PATH`, so the login shell's resolves it as the user's terminal does.
    /// It cannot prompt: there is nobody to answer.
    private static func gh(_ arguments: [String], in directory: URL, environment: [String: String]?) -> Process {
        // Git's process for its cleaned environment; `gh` runs Git itself.
        let process = gitProcess([], in: directory, environment: environment)
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["gh"] + arguments
        process.currentDirectoryURL = directory
        var values = process.environment ?? [:]
        values["GH_PROMPT_DISABLED"] = "1"
        values["GH_NO_UPDATE_NOTIFIER"] = "1"
        values["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = values
        return process
    }
}
