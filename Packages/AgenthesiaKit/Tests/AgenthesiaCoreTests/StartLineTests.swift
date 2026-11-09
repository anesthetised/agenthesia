import Foundation
import Testing

@testable import AgenthesiaCore
@testable import Workspace

/// The line under the first message of a starting session names the fetch, then where the session works (ADR-0040's
/// amendment of 2026-11-07, ADR-0047, ADR-0048).
@MainActor @Suite(.timeLimit(.minutes(1))) struct StartLineTests {
    @Test func theFetchComesFirstThenThePlace() {
        let line = { LiveSession.startLine(agent: "Claude Code", place: $0, fetching: $1) }
        #expect(line(nil, nil) == nil)
        #expect(line(.newWorktree, "origin/main") == "Fetching origin/main…")
        #expect(line(.newWorktree, nil) == "Starting Claude Code in a new worktree…")
        #expect(line(.projectFolder, nil) == "Starting Claude Code in the project folder…")
        #expect(line(.newFolder, nil) == "Starting Claude Code in a new folder…")
        #expect(
            LiveSession.startLine(agent: nil, place: .newFolder, fetching: nil) == "Starting the agent in a new folder…"
        )
    }

    @Test func theCheckoutDecidesThePlace() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "start-place-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(await LiveSession.place(of: nil) == .newFolder)
        #expect(await LiveSession.place(of: directory) == .projectFolder)
        try await SessionWorkspace.git(["init", "-q", "-b", "main"], in: directory)
        #expect(await LiveSession.place(of: directory) == .newWorktree)
        // A Git project's folder, when the draft chose it (ADR-0043).
        #expect(await LiveSession.place(of: directory, inProjectFolder: true) == .projectFolder)
    }
}
