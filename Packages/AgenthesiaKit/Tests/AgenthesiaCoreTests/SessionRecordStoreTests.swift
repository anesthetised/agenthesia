import Foundation
import Testing

@testable import AgenthesiaCore
@testable import Persistence

/// A started session's row holds every column its workspace and startup produced; each layer alone cannot show a
/// column lost between them.
extension WorktreeDiscardTests {
    @Test func aStartedSessionsRowHoldsEveryColumn() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // `main` tracks `origin/main`, but the remote is gone, so the worktree starts from the local branch.
        let remote = fixture.directory.appending(path: "remote.git")
        try await git(["init", "-q", "--bare", "-b", "main", remote.path], in: fixture.directory)
        try await git(["remote", "add", "origin", remote.path], in: fixture.repo)
        try await git(["push", "-q", "-u", "origin", "main"], in: fixture.repo)
        try await git(
            ["remote", "set-url", "origin", fixture.directory.appending(path: "missing.git").path],
            in: fixture.repo
        )

        let (owner, session) = try await start(fixture)
        let store = try await fixture.manager.library.store()
        let row = try #require(try await store.session(id: session.id))

        #expect(row.id == session.id)
        #expect(row.projectID == session.projectID)
        #expect(row.agentInstallID == session.agentInstallID)
        #expect(row.agentSessionID == session.agentSessionID)
        #expect(row.protocolVersion == session.protocolVersion)
        #expect(row.workingDirectory == session.workingDirectory)
        #expect(row.createdAt == session.createdAt)
        #expect(row.fallbackUpstream == "origin/main")
        #expect(row.archivedAt == nil)
        // A column added later and filled at start is not nil in the row.
        let unset = Mirror(reflecting: row).children.compactMap { child -> String? in
            guard let label = child.label, label != "archivedAt", label != "title" else { return nil }
            let value = Mirror(reflecting: child.value)
            return value.displayStyle == .optional && value.children.isEmpty ? label : nil
        }
        #expect(unset.isEmpty, "Unset columns: \(unset)")
        await fixture.manager.end(owner)
    }
}
