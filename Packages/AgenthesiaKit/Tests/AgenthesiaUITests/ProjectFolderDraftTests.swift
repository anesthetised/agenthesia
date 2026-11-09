import AppKit
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// The draft's checkout menu for a Git project (ADR-0043): a new worktree by default, or the project folder, chosen per
/// draft and never remembered.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ProjectFolderDraftTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "project-folder-draft-\(UUID())")
        let sessions: SessionManager
        let model: SessionWindowModel
        var repo: URL { directory.appending(path: "repo") }
        var plain: URL { directory.appending(path: "plain") }

        @MainActor init() async throws {
            try FileManager.default.createDirectory(
                at: directory.appending(path: "plain"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: directory.appending(path: "repo"),
                withIntermediateDirectories: true
            )
            sessions = SessionManager(
                library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")),
                worktreesRoot: directory.appending(path: "trees"),
                scratchRoot: directory.appending(path: "scratch")
            )
            sessions.environment = { (ProcessInfo.processInfo.environment, nil) }
            model = SessionWindowModel(sessions: sessions)
            try await Self.shell(
                "git init -q -b main && git config user.name T && git config user.email t@example.com "
                    + "&& git config commit.gpgSign false && git config core.hooksPath /dev/null "
                    + "&& echo one > kept && git add kept && git commit -qm Initial",
                in: directory.appending(path: "repo")
            )
        }

        @MainActor func remove() async {
            model.close()
            await sessions.closeAll()
            try? FileManager.default.removeItem(at: directory)
        }

        func mock() throws -> AgentCatalog.Choice {
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            return .custom(.init(executable: binary.path, arguments: ["--reopen"]))
        }

        static func shell(_ command: String, in directory: URL) async throws {
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
    }

    private func popups(in view: NSView) -> [NSPopUpButton] {
        ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap(popups)
    }

    @Test(arguments: [false, true])
    func theCheckoutIsAMenuOnlyForAGitProject(dark: Bool) async throws {
        let fixture = try await Fixture()
        let model = fixture.model
        model.draftAgent = try fixture.mock()
        model.draftDirectory = fixture.repo
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SessionDraftView(model: model).frame(width: 800, height: 400))
        let window = OffscreenWindow(size: .init(width: 800, height: 400))
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func checkout() async throws -> [String] {
            try await Task.sleep(for: .milliseconds(200))
            for _ in 0..<30 { await Task.yield(); host.layoutSubtreeIfNeeded() }
            // The agent's menu comes first.
            return popups(in: host).dropFirst().map(\.title)
        }
        #expect(try await checkout() == ["New worktree from main"])
        model.draftInProjectFolder = true
        #expect(try await checkout() == ["Project folder"])
        // Outside Git the chip is a label; without a project it is hidden.
        model.draftDirectory = fixture.plain
        #expect(try await checkout().isEmpty)
        model.draftDirectory = fixture.repo
        model.draftWithoutProject = true
        #expect(try await checkout().isEmpty)
        await fixture.remove()
    }

    @Test func theChoiceIsPerDraftAndSendStartsInTheProjectFolder() async throws {
        let fixture = try await Fixture()
        let model = fixture.model
        model.draftAgent = try fixture.mock()
        model.draftDirectory = fixture.repo
        #expect(!model.draftInProjectFolder)
        // Another project starts with a worktree again.
        model.draftInProjectFolder = true
        model.draftDirectory = fixture.plain
        #expect(!model.draftInProjectFolder)
        model.draftDirectory = fixture.repo
        model.draftInProjectFolder = true
        model.draft = PromptDraft(text: "Where is the retry logic?")
        model.startDraft()
        #expect(!model.draftInProjectFolder)
        let owner = try #require(model.owner)
        await owner.startup?.value
        let session = try #require(owner.controller?.session)
        #expect(owner.startPlace == .projectFolder)
        #expect(session.workingDirectory == fixture.repo.resolvingSymlinksInPath().path)
        #expect(session.branch == nil && session.baseBranch == "main" && session.baseRevision != nil)
        await model.refresh()
        #expect(model.displaysProjectFolderSession)
        // New Session in Project opens the draft with a worktree.
        let project = try #require(model.projects.first { $0.id == session.projectID })
        model.draftInProjectFolder = true
        model.newSession(in: project)
        #expect(model.showingSetup && !model.draftInProjectFolder)
        await fixture.remove()
    }

    @Test func aFailedStartReturnsTheProjectFolderChoice() async throws {
        let fixture = try await Fixture()
        let model = fixture.model
        model.draftAgent = .custom(.init(executable: "/does-not-exist", arguments: []))
        model.draftDirectory = fixture.repo
        model.draftInProjectFolder = true
        model.draft = PromptDraft(text: "hello")
        model.startDraft()
        let owner = try #require(model.owner)
        await owner.startup?.value
        await model.returnToDraft()
        #expect(model.inDraft && model.draftInProjectFolder && model.draftError != nil)
        await fixture.remove()
    }
}
