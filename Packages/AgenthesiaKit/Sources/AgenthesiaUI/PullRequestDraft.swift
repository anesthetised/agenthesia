import AgenthesiaCore
import Foundation
import Observation
import Persistence

/// The Open Pull Request sheet's state for one session (ADR-0045).
@Observable final class PullRequestDraft: Identifiable {
    let session: SessionRecord
    let target: SessionManager.PullRequestTarget
    var title: String
    var body = ""
    /// The step Create is at, or the one that failed; nil before Create.
    var step: SessionManager.PullRequestStep?
    var isRunning = false
    /// The first failure, with Git's or `gh`'s output.
    var failure: String?
    var id: UUID { session.id }

    init(session: SessionRecord, target: SessionManager.PullRequestTarget, title: String) {
        self.session = session
        self.target = target
        self.title = title
    }

    var canCreate: Bool { !isRunning && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func label(of step: SessionManager.PullRequestStep) -> String {
        switch step {
        case .committing: "Commit uncommitted changes"
        case .pushing: "Push \(target.branch) to \(target.remote)"
        case .creating: "Create the pull request"
        }
    }
}
