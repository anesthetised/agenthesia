import AppKit
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SessionInspectorTests {
    struct Fixture {
        let directory: URL
        let model: SessionWindowModel
        let record: SessionRecord
    }

    /// A MockAgent session in `repo`, which is a Git repository on `main` when `git` is set.
    func fixture(git: Bool) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "inspector-\(UUID())")
        let repo = directory.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        if git {
            try await shell(
                "git init -q -b main && git config user.name T && git config user.email t@example.com "
                    + "&& git config commit.gpgSign false && git config core.hooksPath /dev/null "
                    + "&& printf 'one\\ntwo\\n' > kept && git add kept && git commit -qm Initial",
                in: repo
            )
        }
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
        await owner.startup?.value
        await model.refresh()
        let record = try #require(owner.controller?.session)
        await model.files.attach(record)
        return Fixture(directory: directory, model: model, record: record)
    }

    func shell(_ command: String, in directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let status = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        #expect(status == 0)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(5)) }

    private func host<V: View>(_ view: V, dark: Bool = false, width: CGFloat = 260) -> (NSHostingView<V>, NSWindow) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: width, height: 900),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        return (host, window)
    }

    /// The height the inspector's content asks for: every section adds to it.
    private func height(of model: SessionWindowModel, dark: Bool = false) async -> CGFloat {
        let (view, window) = host(
            SessionInspector(model: model, showingLog: .constant(false), onOpen: { _, _ in }),
            dark: dark
        )
        defer { window.close() }
        for _ in 0..<20 { await settle() }
        return view.fittingSize.height
    }

    @Test func onlyWorktreeSessionsHaveABranch() async throws {
        let fixture = try await fixture(git: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let name = "agenthesia/\(fixture.record.id.uuidString.lowercased())"
        #expect(SessionInspector.branchName(of: fixture.record) == name)
        #expect(fixture.record.baseBranch == "main")
        let legacy = SessionRecord(projectID: UUID(), agentInstallID: UUID(), workingDirectory: "/tmp")
        #expect(SessionInspector.branchName(of: legacy) == nil)
    }

    @Test func countsReadAsAddedAndRemoved() {
        #expect(ChangeCounts.label(.init(added: 2, removed: 1)) == "2 added, 1 removed")
        #expect(ChangeCounts.label(.init(added: 0, removed: 0)) == "0 added, 0 removed")
    }

    @Test(arguments: [false, true])
    func aWorktreeSessionShowsChangesWithCounts(dark: Bool) async throws {
        let fixture = try await fixture(git: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let working = URL(filePath: fixture.record.workingDirectory)
        let empty = await height(of: fixture.model, dark: dark)
        try "one\nchanged\nthree\n".write(to: working.appending(path: "kept"), atomically: true, encoding: .utf8)
        try "new\n".write(to: working.appending(path: "added.txt"), atomically: true, encoding: .utf8)
        await fixture.model.files.refresh()
        // 1 added and 1 removed in `kept` (the second line changed, a third was added: +2 −1), 1 added in `added.txt`.
        let stats = fixture.model.files.changeStats
        #expect(stats.total == .init(added: 3, removed: 1))
        #expect(fixture.model.files.changedPaths == ["added.txt", "kept"])
        #expect(fixture.model.canReview && fixture.model.canMerge && fixture.model.canDiscard)
        #expect(await height(of: fixture.model, dark: dark) > empty)
    }

    @Test func eachSectionAddsToTheInspector() async throws {
        let git = try await fixture(git: true)
        let plain = try await fixture(git: false)
        defer {
            try? FileManager.default.removeItem(at: git.directory)
            try? FileManager.default.removeItem(at: plain.directory)
        }
        let withBranch = await height(of: git.model)
        let withoutBranch = await height(of: plain.model)
        #expect(withoutBranch > 0)
        #expect(withBranch > withoutBranch, "Branch is missing from the Git session")
        #expect(plain.model.files.isGitRepository == false)
        // A saved session has no agent to show.
        await git.model.sessions.closeAll()
        await git.model.refresh()
        await git.model.showHistory(try #require(git.model.history.first))
        #expect(git.model.restored != nil)
        await git.model.files.attach(git.model.filesSession)
        #expect(await height(of: git.model) < withBranch, "Agent is shown for a saved session")
    }

    @Test func theRootViewHostsTheInspectorBesideTheLaunchFormAndSessions() async throws {
        let fixture = try await fixture(git: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        let (view, window) = host(RootView(model: model), width: 1600)
        defer { model.close(); window.close() }
        for _ in 0..<30 { await settle() }
        #expect(view.frame.width > 0)
        model.showingSetup = true
        for _ in 0..<30 { await settle() }
        model.showingSetup = false
        for _ in 0..<30 { await settle() }
        #expect(model.displayed != nil)
    }
}
