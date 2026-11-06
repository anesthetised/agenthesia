import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore

/// A start that never got a history record removes the worktree it made, and nothing else (#176).
@MainActor @Suite(.timeLimit(.minutes(1))) struct UnstartedWorktreeTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unstarted-worktree-\(UUID())")
        let library: SessionLibrary
        var repo: URL { directory.appending(path: "repo") }
        var trees: URL { directory.appending(path: "trees") }

        init() {
            library = SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite"))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func prepareRepository() async throws {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try await git(["init", "-q", "-b", "main"], in: repo)
            try "initial".write(to: repo.appending(path: "file.txt"), atomically: true, encoding: .utf8)
            try await git(["add", "."], in: repo)
            try await git(["commit", "-qm", "Initial"], in: repo)
        }

        /// MockAgent that asks for sign-in because the sign-in file does not exist.
        func signedOutAgent() throws -> AgentInstallRecord {
            try mock(["--auth", "--auth-file", directory.appending(path: "signed-in").path(percentEncoded: false)])
        }

        func mock(_ arguments: [String] = []) throws -> AgentInstallRecord {
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            return AgentInstallRecord(name: "Mock", executable: binary.path, arguments: arguments)
        }

        @MainActor func start(_ agent: AgentInstallRecord, initialPrompt: PromptDraft? = nil) async -> LiveSession {
            let owner = LiveSession(library: library)
            owner.environment = { (ProcessInfo.processInfo.environment, nil) }
            await owner.start(directory: repo, agent: agent, worktreesRoot: trees, initialPrompt: initialPrompt)
            return owner
        }

        /// The session worktrees of the repository, as directory names under the worktrees root.
        func worktrees() async throws -> [String] {
            try await git(["worktree", "list", "--porcelain"], in: repo).split(separator: "\n")
                .filter { $0.hasPrefix("worktree ") && $0.contains("/trees/") }
                .compactMap { $0.split(separator: "/").last.map(String.init) }
        }

        func branches() async throws -> [String] {
            try await git(["branch", "--format=%(refname:short)"], in: repo).split(separator: "\n").map(String.init)
        }

        func expectNoSessionWorktree() async throws {
            #expect(try await worktrees().isEmpty)
            #expect(try await branches() == ["main"])
        }
    }

    @Test func cancellingAtSignInRemovesTheWorktreeAndBranch() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try await fixture.prepareRepository()
        let owner = await fixture.start(try fixture.signedOutAgent(), initialPrompt: .init(text: "Fix the note parser"))
        let directory = try #require(owner.workingDirectory)
        let id = try #require(owner.controller?.session.id)
        #expect(owner.signIn != nil)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        // The readable name, stored with the record; the directory keeps the session id.
        let branch = "agenthesia/fix-the-note-parser-\(id.uuidString.lowercased().prefix(8))"
        #expect(owner.controller?.session.branch == branch)
        #expect(try await fixture.worktrees() == [id.uuidString.lowercased()])
        #expect(try await fixture.branches().sorted() == [branch, "main"])
        await owner.close()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try await fixture.expectNoSessionWorktree()
        #expect(owner.workingDirectory == nil)
        #expect(try await fixture.library.history().isEmpty)
        // Closing again has nothing left to remove.
        await owner.close()
        try await fixture.expectNoSessionWorktree()
    }

    @Test func aFailureAfterTheWorktreeWasPreparedRemovesIt() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try await fixture.prepareRepository()
        // The executable exists, so the start passes its checks and prepares a worktree, then the agent
        // exits before answering `initialize`.
        let owner = await fixture.start(AgentInstallRecord(name: "Exits", executable: "/usr/bin/false"))
        #expect(owner.errorMessage != nil)
        #expect(!owner.isLive)
        // The controller exists only once the worktree was prepared.
        #expect(try #require(owner.controller).session.agentSessionID == nil)
        try await fixture.expectNoSessionWorktree()
        #expect(try await fixture.library.history().isEmpty)
        await owner.close()
    }

    @Test func aStartedSessionKeepsItsWorktreeAfterEndSession() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try await fixture.prepareRepository()
        let owner = await fixture.start(try fixture.mock(["--reopen"]))
        let session = try #require(owner.controller?.session)
        #expect(owner.controller?.status == .idle)
        await owner.close()
        #expect(try await fixture.library.history().map(\.id) == [session.id])
        #expect(FileManager.default.fileExists(atPath: session.workingDirectory))
        #expect(try await fixture.worktrees() == [session.id.uuidString.lowercased()])
        #expect(try await fixture.branches().sorted() == [try #require(session.branch), "main"])
    }

    @Test func aWorktreeWithAStrayFileIsLeftInPlace() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try await fixture.prepareRepository()
        let owner = await fixture.start(try fixture.signedOutAgent())
        let directory = try #require(owner.workingDirectory)
        try "work".write(to: directory.appending(path: "stray.txt"), atomically: true, encoding: .utf8)
        await owner.close()
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "stray.txt").path))
        #expect(try await fixture.worktrees().count == 1)
        #expect(try await fixture.branches().count == 2)
    }

    @Test func aBranchWithACommitIsLeftInPlace() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try await fixture.prepareRepository()
        let owner = await fixture.start(try fixture.signedOutAgent())
        let directory = try #require(owner.workingDirectory)
        try "work".write(to: directory.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: directory)
        try await git(["commit", "-qm", "Work"], in: directory)
        await owner.close()
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "work.txt").path))
        #expect(try await fixture.worktrees().count == 1)
        #expect(try await fixture.branches().count == 2)
    }

    @Test func aFolderOutsideGitHasNothingToRemove() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.repo, withIntermediateDirectories: true)
        try "mine".write(to: fixture.repo.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        let owner = await fixture.start(try fixture.signedOutAgent())
        #expect(owner.signIn != nil)
        await owner.close()
        #expect(FileManager.default.fileExists(atPath: fixture.repo.appending(path: "file.txt").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.trees.path))
    }
}

@discardableResult private func git(_ arguments: [String], in directory: URL) async throws -> String {
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
