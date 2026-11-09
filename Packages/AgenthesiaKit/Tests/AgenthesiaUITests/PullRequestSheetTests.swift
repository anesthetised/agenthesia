import AppKit
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// The Open Pull Request sheet's states, hosted off screen (ADR-0045).
@Suite @MainActor struct PullRequestSheetTests {
    func draft() -> PullRequestDraft {
        PullRequestDraft(
            session: SessionRecord(projectID: UUID(), agentInstallID: UUID(), workingDirectory: "/tmp/session"),
            target: .init(remote: "origin", base: "main", branch: "fix-login"),
            title: "Fix the login"
        )
    }

    /// Lays the sheet out at its width and returns its fitting size.
    func host(_ draft: PullRequestDraft) -> NSSize {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: PullRequestSheet(draft: draft) {})
        let window = OffscreenWindow(size: .init(width: 480, height: 600))
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func namesTheStepsAndNeedsATitle() {
        let draft = draft()
        #expect(draft.canCreate)
        #expect(draft.label(of: .committing) == "Commit uncommitted changes")
        #expect(draft.label(of: .pushing) == "Push fix-login to origin")
        #expect(draft.label(of: .creating) == "Create the pull request")
        draft.title = "  "
        #expect(!draft.canCreate)
        draft.title = "Fix"
        draft.isRunning = true
        #expect(!draft.canCreate)
    }

    @Test func fitsItsWidthWhileRunningAndWithALongFailure() {
        let draft = draft()
        #expect(host(draft).width <= 480)
        draft.isRunning = true
        draft.step = .pushing
        #expect(host(draft).width <= 480)
        draft.isRunning = false
        draft.step = .creating
        draft.failure =
            "The branch is pushed, but the pull request was not created.\n\n"
            + String(repeating: "GraphQL: a long line of output from gh ", count: 40)
        #expect(host(draft).width <= 480)
    }
}
