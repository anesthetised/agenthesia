import AgenthesiaCore
import AppKit
import Persistence
import SwiftUI
import Testing

@testable import AgenthesiaUI
@testable import Workspace

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionReviewPaneTests {
    @Test(arguments: [false, true]) func fileListSelectionAndBinaryNotice(dark: Bool) async throws {
        let root = ScopedFileAccess(roots: [
            FileManager.default.temporaryDirectory.appending(path: "review-view-\(UUID())")
        ]).roots[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await SessionWorkspace.git(["init", "-q"], in: root)
        try await SessionWorkspace.git(
            [
                "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c",
                "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "Initial",
            ],
            in: root
        )
        try Data([0, 1]).write(to: root.appending(path: "binary"))
        try "new\n".write(to: root.appending(path: "text"), atomically: true, encoding: .utf8)
        let session = SessionRecord(projectID: UUID(), agentInstallID: UUID(), workingDirectory: root.path)
        let review = SessionReview(session: session, root: root)
        await review.refresh()
        let files = SessionFiles()
        await files.attach(session)
        defer { files.close() }
        let model = SessionWindowModel(sessions: SessionManager())
        let host = NSHostingView(
            rootView: SessionReviewPane(review: review, files: files, model: model, height: 500)
        )
        let window = OffscreenWindow(size: .init(width: 800, height: 500))
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let table = try #require(descendant(NSTableView.self, in: host))
        #expect(table.numberOfRows == 2)
        #expect(review.changes.map(\.path) == ["binary", "text"])
        await settle(host) { review.documentError != nil }
        #expect(review.documentError == SessionFileDocument.Failure.notText.localizedDescription)
        // The native list's selection is also the path loaded for keyboard navigation.
        let down = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\u{F701}",
                charactersIgnoringModifiers: "\u{F701}",
                isARepeat: false,
                keyCode: 125
            )
        )
        table.keyDown(with: down)
        await settle(host) { review.document?.new == "new\n" }
        #expect(review.selectedPath == "text")
        #expect(review.document?.new == "new\n")
        await settle(host) { descendant(DiffTextView.self, in: host)?.string.contains("+new") == true }
        let text = try #require(descendant(DiffTextView.self, in: host))
        #expect(text.string.contains("+new"))
        #expect(!text.isEditable && text.isSelectable)
        try "watched\n".write(to: root.appending(path: "text"), atomically: true, encoding: .utf8)
        await settle(host) { text.string.contains("+watched") }
        #expect(review.document?.new == "watched\n")
        #expect(descendant(DiffTextView.self, in: host) === text)
        #expect(review.selectedPath == "text")
        review.selectedPath = "binary"
        await settle(host) { table.selectedRow == 0 && review.documentError != nil }
        #expect(table.selectedRow == 0)
        // The list takes at most a third of the pane.
        #expect(try #require(table.enclosingScrollView).frame.height <= 500 / 3 + 1)
        for width in [260.0, 560.0] {
            window.setContentSize(NSSize(width: width, height: 500))
            host.layoutSubtreeIfNeeded()
            #expect(host.convert(table.bounds, from: table).maxX <= host.bounds.maxX + 1)
        }
    }

    @Test func reviewCommandRequiresTheDisplayedWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "review-command-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessions = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        let store = try await sessions.library.store()
        let project = ProjectRecord(name: "Review", rootPath: root.path)
        let agent = AgentInstallRecord(name: "Unused", executable: "unused")
        let session = SessionRecord(projectID: project.id, agentInstallID: agent.id, workingDirectory: root.path)
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        try await store.createSession(session)
        let model = SessionWindowModel(sessions: sessions)
        defer { model.close() }
        #expect(!model.canReview)
        model.toggleReview()
        #expect(model.review == nil && !model.isReviewShown)
        await model.showHistory(session)
        await model.files.attach(session)
        #expect(!model.canReview)
        try await SessionWorkspace.git(["init", "-q"], in: root)
        try await SessionWorkspace.git(
            [
                "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c",
                "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "Initial",
            ],
            in: root
        )
        await model.files.refresh()
        #expect(model.canReview)
        model.toggleReview()
        #expect(model.review?.id == session.id && model.isReviewShown)
        let review = model.review
        model.toggleReview()
        #expect(!model.isReviewShown && model.review === review)
        model.toggleReview()
        #expect(model.isReviewShown && model.review === review)
        model.showingSetup = true
        #expect(!model.canReview)
        model.showingSetup = false
        await model.files.attach(
            SessionRecord(projectID: project.id, agentInstallID: agent.id, workingDirectory: root.path)
        )
        #expect(!model.canReview)
        model.close()
        #expect(model.review == nil && !model.canReview)
    }

    @Test func theHostedListFollowsMarksAndTheFooterSummarisesThem() async throws {
        let root = ScopedFileAccess(roots: [
            FileManager.default.temporaryDirectory.appending(path: "review-marks-\(UUID())")
        ]).roots[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await commitEmpty(in: root)
        try "one\ntwo\n".write(to: root.appending(path: "a"), atomically: true, encoding: .utf8)
        try "three\n".write(to: root.appending(path: "b"), atomically: true, encoding: .utf8)
        let session = SessionRecord(projectID: UUID(), agentInstallID: UUID(), workingDirectory: root.path)
        let review = SessionReview(session: session, root: root)
        await review.refresh()
        let files = SessionFiles()
        await files.attach(session)
        defer { files.close() }
        let model = SessionWindowModel(sessions: SessionManager())
        let host = NSHostingView(rootView: SessionReviewPane(review: review, files: files, model: model, height: 500))
        let window = OffscreenWindow(size: .init(width: 800, height: 500))
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let table = try #require(descendant(NSTableView.self, in: host))
        #expect(table.numberOfRows == 2)
        #expect(review.viewedSummary == "0 of 2 viewed")
        #expect(review.stats.files["a"] == ChangeStats.Lines(added: 2, removed: 0))
        // The pane re-renders from the shared marks without losing its list or selection.
        review.toggleViewed("a")
        #expect(review.viewedSummary == "1 of 2 viewed")
        review.markSelectedViewedAndAdvance()
        #expect(review.selectedPath == "b" && review.viewedSummary == "1 of 2 viewed")
        review.markSelectedViewedAndAdvance()
        #expect(review.viewedSummary == "2 of 2 viewed")
        review.toggleViewed("a")
        host.layoutSubtreeIfNeeded()
        #expect(table.numberOfRows == 2 && review.viewedSummary == "1 of 2 viewed")
    }

    @Test func marksOutliveTheReviewAndTheCommandFollowsThePane() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "review-marks-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        let store = try await sessions.library.store()
        let project = ProjectRecord(name: "Marks", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Unused", executable: "unused")
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        var records: [SessionRecord] = []
        for name in ["one", "two"] {
            let root = directory.appending(path: name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await commitEmpty(in: root)
            try "x\n".write(to: root.appending(path: "file"), atomically: true, encoding: .utf8)
            let record = SessionRecord(projectID: project.id, agentInstallID: agent.id, workingDirectory: root.path)
            try await store.createSession(record)
            records.append(record)
        }
        let model = SessionWindowModel(sessions: sessions)
        defer { model.close() }
        #expect(!model.canMarkViewed)
        model.markViewedAndAdvance()
        await model.showHistory(records[0])
        await model.files.attach(records[0])
        model.toggleReview()
        let first = try #require(model.review)
        await first.refresh()
        #expect(model.canMarkViewed)
        model.markViewedAndAdvance()
        #expect(first.viewedCount == 1)
        model.toggleReview()
        #expect(!model.canMarkViewed)
        await model.showHistory(records[1])
        await model.files.attach(records[1])
        model.toggleReview()
        #expect(model.review !== first && model.review?.viewedCount == 0)
        await model.showHistory(records[0])
        await model.files.attach(records[0])
        model.toggleReview()
        let again = try #require(model.review)
        await again.refresh()
        #expect(again !== first && again.viewedCount == 1)
    }

    private func commitEmpty(in root: URL) async throws {
        try await SessionWorkspace.git(["init", "-q"], in: root)
        try await SessionWorkspace.git(
            [
                "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c",
                "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "Initial",
            ],
            in: root
        )
    }

    private func descendant<V: NSView>(_ type: V.Type, in root: NSView) -> V? {
        if let match = root as? V { return match }
        return root.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private func settle(_ host: NSView, until predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
    }
}
