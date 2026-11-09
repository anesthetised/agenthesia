import AgenthesiaCore
import SwiftUI

/// The window's Open Pull Request sheet, and the checks behind the action: again when the displayed session, its
/// files, its turn or its pull request change.
struct PullRequestFlow: ViewModifier {
    @Bindable var model: SessionWindowModel

    func body(content: Content) -> some View {
        content
            .task(id: Key(model: model)) { await model.refreshPullRequest() }
            .sheet(item: $model.pullRequestDraft) { draft in
                PullRequestSheet(draft: draft) { Task { await model.confirmPullRequest(draft) } }
            }
    }

    private struct Key: Equatable {
        let session: UUID?
        let files: Int
        let status: SessionController.Status?
        let pullRequest: Int?

        init(model: SessionWindowModel) {
            session = model.displayed?.session.id
            files = model.files.indexRevision
            status = model.displayed?.status
            pullRequest = model.displayedPullRequest?.number
        }
    }
}
