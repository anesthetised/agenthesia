import Foundation
import Testing

@testable import AgenthesiaCore
@testable import Persistence

@MainActor @Suite(.timeLimit(.minutes(1))) struct WorktreeDiscardTests {
    struct Fixture {
        let directory: URL
        let repo: URL
        let trees: URL
        let manager: SessionManager
        let agent: AgentInstallRecord
    }

    func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "worktree-discard-\(UUID())")
        let repo = directory.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"], in: repo)
        try "initial".write(to: repo.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: repo)
        try await git(["commit", "-qm", "Initial"], in: repo)
        let trees = directory.appending(path: "trees")
        let manager = SessionManager(
            library: SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite")),
            worktreesRoot: trees
        )
        manager.environment = { (ProcessInfo.processInfo.environment, nil) }
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        let agent = AgentInstallRecord(name: "Mock", executable: binary.path, arguments: ["--reopen"])
        return Fixture(directory: directory, repo: repo, trees: trees, manager: manager, agent: agent)
    }

    /// Starts a session in a fresh worktree and waits until it is idle.
    func start(_ fixture: Fixture, in directory: URL? = nil) async throws -> (LiveSession, SessionRecord) {
        let owner = fixture.manager.start(directory: directory ?? fixture.repo, agent: fixture.agent)
        await owner.startup?.value
        return (owner, try #require(owner.controller?.session))
    }

    func project(of session: SessionRecord, in manager: SessionManager) async throws -> ProjectRecord? {
        try await manager.library.projects().first { $0.id == session.projectID }
    }

    func branches(_ repo: URL) async throws -> [String] {
        try await git(["branch", "--format=%(refname:short)"], in: repo).split(separator: "\n").map(String.init)
    }

    @Test func discardEndsALiveSessionAndRecordsTheOutcome() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await start(fixture)
        let (other, otherSession) = try await start(fixture)
        await owner.send("hello")
        try "dirty".write(
            to: URL(filePath: session.workingDirectory).appending(path: "file.txt"),
            atomically: true,
            encoding: .utf8
        )
        #expect(manager.canDiscard(session, project: try await project(of: session, in: manager)))
        let summary = try await manager.discardSummary(session)
        #expect(
            summary
                == .init(uncommittedFiles: 1, commits: 0, branch: "agenthesia/\(session.id.uuidString.lowercased())")
        )
        try await manager.discard(session)
        #expect(owner.isClosed && manager.owners.map(\.id) == [other.id])
        #expect(!FileManager.default.fileExists(atPath: session.workingDirectory))
        #expect(FileManager.default.fileExists(atPath: otherSession.workingDirectory))
        #expect(
            try await branches(fixture.repo).sorted() == [
                "agenthesia/\(otherSession.id.uuidString.lowercased())", "main",
            ]
        )
        #expect(try await manager.library.worktreeOutcomes() == [session.id: .discarded])
        // History shows the outcome without an agent, and Continue fails before reaching one.
        let restored = try await SessionController.restore(id: session.id, store: manager.library.store())
        #expect(restored.transcript.worktreeOutcome == .discarded)
        #expect(restored.transcript.items.last?.notice == WorktreeOutcome.discarded.notice)
        let continued = try #require(manager.resume(session))
        await continued.startup?.value
        #expect(continued.controller == nil)
        #expect(continued.errorMessage == "The worktree was discarded. The session cannot continue.")
        await #expect(throws: SessionManager.DiscardError.alreadyRemoved) { try await manager.discard(session) }
        #expect(try await manager.library.store().events(in: session.id).count == restored.transcript.sequence)
        await manager.closeAll()
    }

    @Test func discardsASavedSessionWithCommits() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await start(fixture)
        let working = URL(filePath: session.workingDirectory)
        try "work".write(to: working.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: working)
        try await git(["commit", "-qm", "Work"], in: working)
        await manager.end(owner)
        #expect(try await manager.discardSummary(session).commits == 1)
        try await manager.discard(session)
        #expect(!FileManager.default.fileExists(atPath: session.workingDirectory))
        #expect(try await branches(fixture.repo) == ["main"])
        #expect(try await manager.library.worktreeOutcomes()[session.id] == .discarded)
        #expect(try String(contentsOf: fixture.repo.appending(path: "file.txt"), encoding: .utf8) == "initial")
    }

    @Test func aFailedRemovalRecordsNothingAndARetrySucceeds() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await start(fixture)
        await manager.end(owner)
        let events = try await manager.library.store().events(in: session.id).count
        // A locked worktree needs a second --force, so Git refuses to remove it.
        try await git(["worktree", "lock", session.workingDirectory], in: fixture.repo)
        await #expect(throws: (any Error).self) { try await manager.discard(session) }
        #expect(FileManager.default.fileExists(atPath: session.workingDirectory))
        #expect(try await manager.library.store().events(in: session.id).count == events)
        #expect(try await manager.library.worktreeOutcomes().isEmpty)
        #expect(!manager.isDiscarding(session.id))
        try await git(["worktree", "unlock", session.workingDirectory], in: fixture.repo)
        try await manager.discard(session)
        #expect(try await manager.library.worktreeOutcomes()[session.id] == .discarded)
    }

    @Test func concurrentDiscardsShareOneRemovalAndContinueWaits() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await start(fixture)
        await manager.end(owner)
        let first = Task { try await manager.discard(session) }
        while !manager.isDiscarding(session.id) { await Task.yield() }
        #expect(manager.resume(session) == nil)
        #expect(!manager.canDiscard(session, project: try await project(of: session, in: manager)))
        #expect(manager.discardingIDs == [session.id])
        try await manager.discard(session)
        try await first.value
        #expect(manager.owners.isEmpty && manager.discardingIDs.isEmpty)
        let events = try await manager.library.store().events(in: session.id)
        #expect(events.count { WorktreeOutcome(lastEvent: $0) != nil } == 1)
    }

    @Test func discardIsRefusedWhileTheSessionIsStartingOrContinuing() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await start(fixture)
        await manager.end(owner)
        let gate = DiscardGate()
        manager.environment = { await gate.wait() }
        let continuing = try #require(manager.resume(session))
        while !gate.entered { await Task.yield() }
        #expect(!manager.canDiscard(session, project: try await project(of: session, in: manager)))
        await #expect(throws: SessionManager.DiscardError.starting) { try await manager.discard(session) }
        gate.release()
        await continuing.startup?.value
        #expect(FileManager.default.fileExists(atPath: session.workingDirectory))
        await manager.closeAll()
    }

    @Test func discardIsRefusedWhileTheSessionWaitsForSignIn() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let signInFile = fixture.directory.appending(path: "signed-in").path(percentEncoded: false)
        let agent = AgentInstallRecord(
            name: "Mock",
            executable: fixture.agent.executable,
            arguments: ["--auth", "--auth-file", signInFile]
        )
        let owner = manager.start(directory: fixture.repo, agent: agent)
        await owner.startup?.value
        #expect(owner.signIn != nil)
        // The session has a worktree but no history yet; it can only be ended.
        let session = try #require(owner.controller?.session)
        #expect(!manager.canDiscard(session, project: try await project(of: session, in: manager)))
        await #expect(throws: SessionManager.DiscardError.starting) { try await manager.discard(session) }
        #expect(FileManager.default.fileExists(atPath: session.workingDirectory))
        await manager.closeAll()
    }

    @Test func sessionsOutsideAnAgenthesiaWorktreeAreNeverRemoved() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let plain = fixture.directory.appending(path: "plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let (owner, session) = try await start(fixture, in: plain)
        #expect(session.workingDirectory == plain.resolvingSymlinksInPath().path)
        #expect(!manager.canDiscard(session, project: try await project(of: session, in: manager)))
        #expect(!manager.canDiscard(session, project: nil))
        await #expect(throws: SessionManager.DiscardError.notRemovable) { try await manager.discard(session) }
        #expect(owner.isLive)
        #expect(FileManager.default.fileExists(atPath: plain.path))
        await manager.closeAll()
    }

    @Test func outcomesRoundTripThroughTheEventLog() throws {
        for outcome in [WorktreeOutcome.discarded, .merged(commit: String(repeating: "a", count: 40), into: "main")] {
            let stored = StoredEvent(
                sessionID: UUID(),
                sequence: 1,
                event: try SessionEvent.worktreeRemoved(outcome).storedEvent()
            )
            #expect(WorktreeOutcome(lastEvent: stored) == outcome)
            var transcript = TranscriptState()
            try transcript.apply(stored)
            #expect(transcript.worktreeOutcome == outcome)
            #expect(transcript.items.map(\.notice) == [outcome.notice])
        }
        #expect(
            WorktreeOutcome.merged(commit: "0123456789abcdef", into: "feature/x").notice
                == "Merged into feature/x as 0123456."
        )
        let other = StoredEvent(
            sessionID: UUID(),
            sequence: 1,
            event: try SessionEvent.queuePaused(true).storedEvent()
        )
        #expect(WorktreeOutcome(lastEvent: other) == nil)
    }

    @discardableResult func git(_ arguments: [String], in directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        let process = Process()
                        process.executableURL = URL(filePath: "/usr/bin/git")
                        process.currentDirectoryURL = directory
                        process.arguments =
                            [
                                "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c",
                                "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                            ] + arguments
                        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                        let output = Pipe()
                        process.standardOutput = output
                        process.standardError = output
                        try process.run()
                        let data = output.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
                    }
                )
            }
        }
    }
}

@MainActor final class DiscardGate {
    var entered = false
    private var continuation: CheckedContinuation<([String: String], String?), Never>?
    func wait() async -> ([String: String], String?) {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: (ProcessInfo.processInfo.environment, nil)) }
}
