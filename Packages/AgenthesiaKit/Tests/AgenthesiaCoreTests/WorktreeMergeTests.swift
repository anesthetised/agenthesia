import Foundation
import Testing

@testable import AgenthesiaCore
@testable import Persistence

@MainActor @Suite(.timeLimit(.minutes(1))) struct WorktreeMergeTests {
    typealias Fixture = WorktreeDiscardTests.Fixture
    let helpers = WorktreeDiscardTests()

    /// The discard fixture, with an identity and no hooks or signing for the merge commit.
    func fixture() async throws -> Fixture {
        let fixture = try await helpers.fixture()
        for (key, value) in [
            ("user.name", "Test"), ("user.email", "test@example.com"), ("commit.gpgSign", "false"),
            ("core.hooksPath", "/dev/null"),
        ] {
            try await helpers.git(["config", key, value], in: fixture.repo)
        }
        return fixture
    }

    func write(_ text: String, to path: String, in session: SessionRecord) throws {
        try text.write(
            to: URL(filePath: session.workingDirectory).appending(path: path),
            atomically: true,
            encoding: .utf8
        )
    }

    func lastEvent(of session: SessionRecord, in manager: SessionManager) async throws -> StoredEvent? {
        try await manager.library.store().events(in: session.id).last
    }

    @Test func mergeCommitsTheSessionEndsItAndRecordsTheOutcome() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await helpers.start(fixture)
        let (other, _) = try await helpers.start(fixture)
        await owner.send("Add a greeting\nwith details")
        #expect(owner.controller?.transcript.mergeMessage == "Add a greeting")
        try write("hello", to: "greeting.txt", in: session)
        #expect(try await manager.mergeCheck(session) == .ready(baseBranch: "main", files: 1, commits: 0))

        let commit = try await manager.merge(session, message: "Add a greeting")
        #expect(try await helpers.git(["rev-parse", "main"], in: fixture.repo) == commit)
        #expect(try await helpers.git(["log", "-1", "--format=%s"], in: fixture.repo) == "Add a greeting")
        #expect(try String(contentsOf: fixture.repo.appending(path: "greeting.txt"), encoding: .utf8) == "hello")
        #expect(owner.isClosed && manager.owners.map(\.id) == [other.id])
        #expect(!manager.isMerging(session.id))
        #expect(!FileManager.default.fileExists(atPath: session.workingDirectory))
        #expect(
            !(try await helpers.branches(fixture.repo)).contains("agenthesia/\(session.id.uuidString.lowercased())")
        )
        let outcome = WorktreeOutcome.merged(commit: commit, into: "main")
        #expect(try await manager.library.worktreeOutcomes()[session.id] == outcome)
        #expect(try await lastEvent(of: session, in: manager).flatMap(WorktreeOutcome.init(lastEvent:)) == outcome)
        // History shows the merge without an agent; Continue, discard and a second merge are refused.
        let restored = try await SessionController.restore(id: session.id, store: manager.library.store())
        #expect(restored.transcript.items.last?.notice == "Merged into main as \(commit.prefix(7)).")
        let continued = try #require(manager.resume(session))
        await continued.startup?.value
        #expect(continued.controller == nil)
        await #expect(throws: SessionManager.DiscardError.alreadyRemoved) { try await manager.discard(session) }
        await #expect(throws: (any Error).self) { try await manager.merge(session, message: "Again") }
        await manager.closeAll()
    }

    @Test func mergesASavedSessionWithoutStartingTheAgent() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await helpers.start(fixture)
        let working = URL(filePath: session.workingDirectory)
        try write("work", to: "work.txt", in: session)
        try await helpers.git(["add", "."], in: working)
        try await helpers.git(["commit", "-qm", "Work"], in: working)
        try write("more", to: "more.txt", in: session)
        await manager.end(owner)

        #expect(try await manager.mergeCheck(session) == .ready(baseBranch: "main", files: 2, commits: 1))
        let commit = try await manager.merge(session, message: "Saved work")
        #expect(manager.owners.isEmpty)
        #expect(try await helpers.git(["rev-list", "--count", "HEAD"], in: fixture.repo) == "2")
        #expect(try await manager.library.worktreeOutcomes()[session.id] == .merged(commit: commit, into: "main"))
    }

    @Test func mergeIsRefusedDuringATurn() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await helpers.start(fixture)
        let controller = try #require(owner.controller)
        try write("hello", to: "greeting.txt", in: session)
        #expect(await owner.submit("slow"))
        while controller.status != .running { await Task.yield() }

        #expect(try await manager.mergeCheck(session) == .blocked(SessionManager.MergeError.busyExplanation))
        await #expect(throws: SessionManager.MergeError.busy) { try await manager.merge(session, message: "Busy") }
        #expect(!manager.isMerging(session.id) && !controller.isMerging)
        await owner.stop()
        while controller.status != .idle { await Task.yield() }
        // Stop paused the empty queue, which does not block a merge.
        _ = try await manager.merge(session, message: "After the turn")
        await manager.closeAll()
    }

    @Test func promptsContinueAndDiscardAreRefusedWhileMergingAndQuitWaits() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await helpers.start(fixture)
        let controller = try #require(owner.controller)
        try write("hello", to: "greeting.txt", in: session)
        let gate = DiscardGate()
        manager.environment = { await gate.wait() }
        let merge = Task { try await manager.merge(session, message: "Gated") }
        while !gate.entered { await Task.yield() }

        #expect(manager.isMerging(session.id) && manager.isMergingAny && controller.isMerging)
        #expect(await owner.submit("hello") == false)
        #expect(controller.transcript.items.allSatisfy { $0.message?.role != .user })
        #expect(manager.resume(session) == nil)
        #expect(!manager.canDiscard(session, project: try await helpers.project(of: session, in: manager)))
        await #expect(throws: SessionManager.DiscardError.merging) { try await manager.discard(session) }
        await #expect(throws: SessionManager.MergeError.busy) { try await manager.merge(session, message: "Twice") }
        #expect(try await manager.mergeCheck(session) == .blocked(SessionManager.MergeError.busyExplanation))
        var closed = false
        let closing = Task {
            await manager.closeAll()
            closed = true
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!closed)

        gate.release()
        let commit = try await merge.value
        await closing.value
        #expect(try await manager.library.worktreeOutcomes()[session.id] == .merged(commit: commit, into: "main"))
    }

    @Test func aConflictKeepsTheAgentAndTheSessionUsable() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await helpers.start(fixture)
        let controller = try #require(owner.controller)
        try write("session", to: "file.txt", in: session)
        try "base".write(to: fixture.repo.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        try await helpers.git(["commit", "-qam", "Base"], in: fixture.repo)
        let base = try await helpers.git(["rev-parse", "HEAD"], in: fixture.repo)

        await #expect(throws: SessionManager.MergeError.conflicts(["file.txt"])) {
            try await manager.merge(session, message: "Conflict")
        }
        #expect(try await helpers.git(["rev-parse", "HEAD"], in: fixture.repo) == base)
        #expect(try await helpers.git(["status", "--porcelain"], in: fixture.repo) == "")
        #expect(owner.isLive && !controller.isMerging && !manager.isMerging(session.id))
        #expect(FileManager.default.fileExists(atPath: session.workingDirectory))
        #expect(try await manager.library.worktreeOutcomes().isEmpty)
        // The agent can be asked to resolve the conflict.
        #expect(await owner.submit("merge the base branch"))
        while controller.status != .idle || controller.completedTurns == 0 { await Task.yield() }
        await manager.closeAll()
    }

    @Test func aFailedRemovalKeepsTheMergeAndDiscardFinishesIt() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (owner, session) = try await helpers.start(fixture)
        try write("hello", to: "greeting.txt", in: session)
        // A locked worktree needs a second --force, so Git refuses to remove it.
        try await helpers.git(["worktree", "lock", session.workingDirectory], in: fixture.repo)

        do {
            _ = try await manager.merge(session, message: "Locked")
            Issue.record("The locked worktree was removed.")
        } catch SessionManager.MergeError.worktreeKept(let commit, _) {
            #expect(try await helpers.git(["rev-parse", "main"], in: fixture.repo) == commit)
            #expect(try await manager.library.worktreeOutcomes()[session.id] == .merged(commit: commit, into: "main"))
        }
        #expect(owner.isClosed)
        #expect(FileManager.default.fileExists(atPath: session.workingDirectory))
        #expect(manager.canDiscard(session, project: try await helpers.project(of: session, in: manager)))
        let outcome = try await manager.library.worktreeOutcomes()[session.id]

        try await helpers.git(["worktree", "unlock", session.workingDirectory], in: fixture.repo)
        try await manager.discard(session)
        #expect(!FileManager.default.fileExists(atPath: session.workingDirectory))
        #expect(try await helpers.branches(fixture.repo) == ["main"])
        #expect(try await manager.library.worktreeOutcomes()[session.id] == outcome)
        await #expect(throws: SessionManager.DiscardError.alreadyRemoved) { try await manager.discard(session) }
    }

    @Test func aSessionWithoutABaseBranchIsBlocked() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        try await helpers.git(["checkout", "-q", "--detach"], in: fixture.repo)
        let (owner, session) = try await helpers.start(fixture)
        try write("hello", to: "greeting.txt", in: session)
        #expect(session.baseBranch == nil)
        guard case .blocked(let explanation) = try await manager.mergeCheck(session) else {
            Issue.record("A detached session was mergeable.")
            return
        }
        #expect(explanation.contains("detached HEAD"))
        await #expect(throws: SessionManager.MergeError.blocked(explanation)) {
            try await manager.merge(session, message: "Detached")
        }
        #expect(owner.isLive && FileManager.default.fileExists(atPath: session.workingDirectory))
        await manager.closeAll()
    }

    /// `SessionTests.replayMessagesToolsAndMetadata` covers the agent's title taking precedence.
    @Test func theDefaultMessageIsTheFirstPromptLine() throws {
        var transcript = TranscriptState()
        #expect(transcript.mergeMessage == "")
        let prompt = try SessionEvent.prompt(id: UUID(), content: [.init(text: "\n  Fix the build  \nmore")])
            .storedEvent()
        try transcript.apply(StoredEvent(sessionID: UUID(), sequence: 1, event: prompt))
        #expect(transcript.mergeMessage == "Fix the build")
    }
}
