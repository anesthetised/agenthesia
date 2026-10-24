import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct MergeWindowTests {
    struct Fixture {
        let directory: URL
        let repo: URL
        let model: SessionWindowModel
        let owner: LiveSession
        let record: SessionRecord
    }

    /// A repository on `main` and a MockAgent session in its worktree, shown in a window.
    func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-merge-\(UUID())")
        let repo = directory.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await shell(
            "git init -q -b main && git config user.name T && git config user.email t@example.com "
                + "&& git config commit.gpgSign false && git config core.hooksPath /dev/null "
                + "&& echo initial > file && git add file && git commit -qm Initial",
            in: repo
        )
        let sessions = SessionManager(
            library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")),
            worktreesRoot: directory.appending(path: "trees")
        )
        sessions.environment = { (ProcessInfo.processInfo.environment, nil) }
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        let model = SessionWindowModel(sessions: sessions)
        model.start(directory: repo, executable: binary.path, arguments: ["--reopen"])
        let owner = try #require(model.owner)
        #expect(!model.canMerge)
        await owner.startup?.value
        await model.refresh()
        return Fixture(
            directory: directory,
            repo: repo,
            model: model,
            owner: owner,
            record: try #require(owner.controller?.session)
        )
    }

    func shell(_ command: String, in directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        // Waiting synchronously would block the main actor shared by the other suites.
        let status = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        #expect(status == 0)
    }

    @Test func mergeShowsTheSessionReadOnlyAndClosesTheSheets() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        await fixture.owner.send("Add a greeting\nPlease")
        try "hello".write(
            to: URL(filePath: fixture.record.workingDirectory).appending(path: "greeting"),
            atomically: true,
            encoding: .utf8
        )
        #expect(model.canMerge && model.mergeCommandTitle == "Merge into main…")
        await model.files.attach(fixture.record)
        model.openReview()
        #expect(model.review != nil)

        await model.requestMerge()
        let request = try #require(model.merge)
        #expect(request.title == "Merge into main")
        #expect(request.check == .ready(baseBranch: "main", files: 1, commits: 0))
        #expect(request.message == "Add a greeting" && request.canMerge && !request.isBlocked)
        request.message = "  \n"
        #expect(!request.canMerge)
        request.message = "Add a greeting"

        await model.confirmMerge(request)
        #expect(model.merge == nil && model.review == nil && model.alertMessage == nil)
        #expect(model.sessions.owners.isEmpty)
        guard case .merged(let commit, "main") = try #require(model.restored?.transcript.worktreeOutcome) else {
            Issue.record("The merge was not recorded.")
            return
        }
        #expect(
            RootView.statusText(try #require(model.restored)) == "Merged into main as \(commit.prefix(7)). Read-only."
        )
        #expect(!model.canMerge && !model.canDiscard && !model.canContinue && model.filesSession == nil)
        #expect(try String(contentsOf: fixture.repo.appending(path: "greeting"), encoding: .utf8) == "hello")
    }

    @Test func blockersAndConflictsStayInTheSheet() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        try "session".write(
            to: URL(filePath: fixture.record.workingDirectory).appending(path: "file"),
            atomically: true,
            encoding: .utf8
        )
        try "edited".write(to: fixture.repo.appending(path: "file"), atomically: true, encoding: .utf8)
        await model.requestMerge()
        let blocked = try #require(model.merge)
        #expect(
            blocked.check
                == .blocked(
                    "The project checkout has uncommitted changes to tracked files. Commit or stash them to merge."
                )
        )
        #expect(blocked.isBlocked && !blocked.canMerge)

        try await shell("git commit -qam Base", in: fixture.repo)
        await model.requestMerge()
        let request = try #require(model.merge)
        #expect(request !== blocked && request.check == .ready(baseBranch: "main", files: 1, commits: 0))
        request.message = "Conflicting"
        await model.confirmMerge(request)
        #expect(model.merge === request && !request.isMerging)
        #expect(request.failure == .conflicts(["file"]))
        #expect(request.message == "Conflicting" && request.canMerge)
        #expect(fixture.owner.isLive && model.canMerge && model.outcomes.isEmpty)
        await model.sessions.closeAll()
    }

    @Test func theSummaryCountsFilesAndCommits() {
        #expect(
            MergeSheet.summary(base: "main", files: 1, commits: 1)
                == "1 changed file and 1 commit become one commit on main. Uncommitted changes are included."
        )
        #expect(MergeSheet.summary(base: "dev", files: 3, commits: 0).hasPrefix("3 changed files and 0 commits"))
    }
}
