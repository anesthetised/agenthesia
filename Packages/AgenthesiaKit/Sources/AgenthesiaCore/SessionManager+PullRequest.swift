public import Foundation
public import Persistence
import Workspace

/// Pull requests from a session's branch with the GitHub CLI (ADR-0045). The session stays live: its worktree,
/// branch and agent remain, and Push sends later work to the same pull request.
extension SessionManager {
    /// Where a session's pull request goes.
    public struct PullRequestTarget: Equatable, Sendable {
        /// The remote of the base branch's upstream; the session branch is pushed there.
        public let remote: String
        /// The base branch's name on the remote.
        public let base: String
        public let branch: String
    }

    /// The steps of Create, in order.
    public enum PullRequestStep: Int, CaseIterable, Comparable, Sendable {
        case committing, pushing, creating

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct PullRequestError: LocalizedError, Equatable {
        public enum Failure: Equatable, Sendable {
            case busy
            /// The step that failed, with Git's or `gh`'s output.
            case step(PullRequestStep, output: String)
            /// `gh` opened the pull request, but history could not record it.
            case notRecorded(PullRequest, reason: String)
        }

        public let failure: Failure

        public var errorDescription: String? {
            switch failure {
            case .busy:
                "The session is working, starting, or being merged, discarded or pushed. Try again once it is idle, "
                    + "with no queued prompts waiting to be sent."
            case .step(.committing, let output): "The uncommitted changes could not be committed.\n\n\(output)"
            case .step(.pushing, let output): "The branch could not be pushed.\n\n\(output)"
            case .step(.creating, let output):
                "The branch is pushed, but the pull request was not created.\n\n\(output)"
            case .notRecorded(let pullRequest, let reason):
                "Pull request #\(pullRequest.number) was opened at \(pullRequest.url.absoluteString), but history "
                    + "could not record it. \(reason)"
            }
        }
    }

    /// Where the session's pull request would go, or nil when Open Pull Request… is hidden: the session has no
    /// worktree of its own or it already ended, its base branch tracks no remote branch, or `gh` is missing or
    /// signed out. A positive `gh` answer is kept for the rest of the launch.
    public func pullRequestTarget(_ session: SessionRecord) async -> PullRequestTarget? {
        guard let base = session.baseBranch, let (worktree, outcome) = try? await removableWorktree(session),
            outcome == nil,
            let upstream = await SessionWorkspace.remoteUpstream(of: base, in: worktree.projectDirectory)
        else { return nil }
        if !gitHubCLISignedIn {
            let values = await (environment ?? LiveSession.shellEnvironment)().values
            gitHubCLISignedIn = await SessionWorkspace.gitHubCLIIsSignedIn(environment: values)
            guard gitHubCLISignedIn else { return nil }
        }
        return PullRequestTarget(remote: upstream.remote, base: upstream.branch, branch: worktree.branch)
    }

    /// The session's worktree has work its pushed branch does not have yet.
    public func hasUnpushedWork(_ session: SessionRecord) async -> Bool {
        guard let (worktree, outcome) = try? await removableWorktree(session), outcome == nil else { return false }
        return await SessionWorkspace.hasUnpushedWork(in: worktree.directory)
    }

    /// Commits the uncommitted changes on the session branch, pushes it (`git push -u`, never forced) and opens
    /// the pull request with `gh`, then records it in the session's log. `onStep` is told each step as it starts.
    /// Throws the first failure; a failure after the push leaves the branch pushed.
    @discardableResult public func openPullRequest(
        _ session: SessionRecord,
        to target: PullRequestTarget,
        title: String,
        body: String,
        onStep: (PullRequestStep) -> Void = { _ in }
    ) async throws -> PullRequest {
        let id = session.id
        let (worktree, values) = try await beginPush(session)
        defer { pushingIDs.remove(id) }
        try await commitAndPush(
            worktree.directory,
            branch: target.branch,
            to: target.remote,
            environment: values,
            onStep: onStep
        )
        onStep(.creating)
        let created: (url: URL, number: Int)
        do {
            created = try await SessionWorkspace.createPullRequest(
                base: target.base,
                head: target.branch,
                title: title,
                body: body,
                in: worktree.directory,
                environment: values
            )
        } catch {
            throw PullRequestError(failure: .step(.creating, output: error.localizedDescription))
        }
        let pullRequest = PullRequest(url: created.url, number: created.number)
        do {
            if let controller = owner(of: id)?.controller {
                try await controller.record(pullRequest)
            } else {
                try await library.record(pullRequest, for: id)
            }
        } catch {
            throw PullRequestError(failure: .notRecorded(pullRequest, reason: error.localizedDescription))
        }
        return pullRequest
    }

    /// Push beside the pull request: commits the uncommitted changes and pushes the session branch to its upstream
    /// again, never forcing, so a branch rewritten on the remote fails with Git's message.
    public func push(_ session: SessionRecord, onStep: (PullRequestStep) -> Void = { _ in }) async throws {
        let (worktree, values) = try await beginPush(session)
        defer { pushingIDs.remove(session.id) }
        let branch = worktree.branch
        guard let upstream = await SessionWorkspace.remoteUpstream(of: branch, in: worktree.directory) else {
            throw PullRequestError(failure: .step(.pushing, output: "“\(branch)” has no upstream on a remote."))
        }
        try await commitAndPush(
            worktree.directory,
            branch: branch,
            to: upstream.remote,
            environment: values,
            onStep: onStep
        )
    }

    /// Refuses a busy session, marks it pushing and returns its worktree and the login shell's environment.
    private func beginPush(_ session: SessionRecord) async throws -> (SessionWorkspace.Worktree, [String: String]) {
        guard canBeginMerge(session.id) else { throw PullRequestError(failure: .busy) }
        pushingIDs.insert(session.id)
        do {
            let (worktree, outcome) = try await removableWorktree(session)
            guard outcome == nil else { throw DiscardError.alreadyRemoved }
            return (worktree, await (environment ?? LiveSession.shellEnvironment)().values)
        } catch {
            pushingIDs.remove(session.id)
            throw error
        }
    }

    private func commitAndPush(
        _ worktree: URL,
        branch: String,
        to remote: String,
        environment: [String: String],
        onStep: (PullRequestStep) -> Void
    ) async throws {
        onStep(.committing)
        do {
            try await SessionWorkspace.commitUncommittedChanges(in: worktree, environment: environment)
        } catch {
            throw PullRequestError(failure: .step(.committing, output: error.localizedDescription))
        }
        onStep(.pushing)
        do {
            try await SessionWorkspace.pushBranch(branch, to: remote, in: worktree, environment: environment)
        } catch {
            throw PullRequestError(failure: .step(.pushing, output: error.localizedDescription))
        }
    }
}
