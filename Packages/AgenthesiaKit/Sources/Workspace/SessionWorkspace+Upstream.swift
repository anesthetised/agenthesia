import Foundation

extension SessionWorkspace {
    /// The branch a local branch tracks (ADR-0047).
    struct Upstream: Equatable {
        /// What `git fetch` takes: the remote (`.` for a local branch) and its branch, e.g. `refs/heads/main`.
        let remote: String
        let remoteBranch: String
        /// The remote-tracking ref `git fetch` updates, e.g. `refs/remotes/origin/main`.
        let ref: String
        /// The short name shown to the user, e.g. `origin/main`.
        let name: String
    }

    /// Nil when `branch` tracks nothing or its configuration is incomplete. Blocks the calling thread.
    static func upstream(of branch: String, in directory: URL) -> Upstream? {
        let format = "%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream)%00%(upstream:short)"
        guard
            let output = try? git(["for-each-ref", "--format=\(format)", "refs/heads/\(branch)"], in: directory)
        else { return nil }
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, !fields.contains(where: \.isEmpty) else { return nil }
        return Upstream(remote: fields[0], remoteBranch: fields[1], ref: fields[2], name: fields[3])
    }

    /// `git fetch` of the upstream's one branch, stopped after `timeout`; whether it succeeded in time. Blocks the
    /// calling thread. Credentials cannot be asked for: there is nobody to answer.
    static func fetch(
        _ upstream: Upstream,
        in directory: URL,
        environment: [String: String]?,
        timeout: Duration
    ) -> Bool {
        var environment = environment ?? ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let process = gitProcess(
            ["fetch", "--quiet", upstream.remote, upstream.remoteBranch],
            in: directory,
            environment: environment
        )
        // Only the exit status matters; no pipe a lingering child could hold open.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return false }
        guard exited.wait(timeout: .now() + timeout / .seconds(1)) == .success else {
            process.terminate()
            exited.wait()
            return false
        }
        return process.terminationStatus == 0
    }
}
