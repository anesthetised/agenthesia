import AppKit
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// Open Pull Request… in a window (ADR-0045), with a local bare repository as `origin` and a fake `gh` on `PATH`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PullRequestWindowTests {
    let merge = MergeWindowTests()

    /// The merge window fixture; with `gh`, `main` tracks a bare `origin` and a fake `gh` answers, failing `pr create`
    /// with `createFailure`.
    func fixture(gh: Bool = true, createFailure: String? = nil) async throws -> MergeWindowTests.Fixture {
        let fixture = try await merge.fixture()
        guard gh else { return fixture }
        let bin = fixture.directory.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let create =
            createFailure.map { "echo '\($0)' >&2; exit 1" } ?? "echo https://github.com/example/repo/pull/12"
        let script = "#!/bin/sh\nif [ \"$1\" = pr ]; then \(create); fi\n"
        try script.write(to: bin.appending(path: "gh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "gh").path)
        let remote = fixture.directory.appending(path: "remote.git").path
        try await merge.shell(
            "git init -q --bare -b main '\(remote)' && git remote add origin '\(remote)' && git push -q -u origin main",
            in: fixture.repo
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        fixture.model.sessions.environment = { [environment] in (environment, nil) }
        return fixture
    }

    func write(_ text: String, to path: String, in fixture: MergeWindowTests.Fixture) throws {
        try text.write(
            to: URL(filePath: fixture.record.workingDirectory).appending(path: path),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Hosts the inspector with the pull request's link and Push, light and dark.
    func inspectorHeight(_ model: SessionWindowModel) async -> CGFloat {
        _ = NSApplication.shared
        var height: CGFloat = 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(
                rootView: SessionInspector(model: model, showingLog: .constant(false), onOpen: { _, _ in })
            )
            let window = OffscreenWindow(size: .init(width: 260, height: 900))
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(5)) }
            height = host.fittingSize.height
            window.close()
        }
        return height
    }

    @Test func opensThePullRequestAndThenOffersPushInsteadOfMerge() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        await fixture.owner.send("Add a greeting\nPlease")
        try write("hello", to: "greeting", in: fixture)
        await model.refreshPullRequest()
        #expect(model.showsOpenPullRequest && model.canOpenPullRequest && model.showsMerge)

        model.requestPullRequest()
        let draft = try #require(model.pullRequestDraft)
        #expect(draft.title == "Add a greeting" && draft.body.isEmpty && draft.canCreate)
        #expect(draft.target.base == "main" && draft.target.remote == "origin")
        draft.title = " "
        #expect(!draft.canCreate)
        draft.title = "Add a greeting"
        await model.confirmPullRequest(draft)
        #expect(draft.failure == nil)
        #expect(model.pullRequestDraft == nil && model.alertMessage == nil)
        #expect(model.displayedPullRequest?.number == 12)
        #expect(!model.showsMerge && !model.showsOpenPullRequest)
        #expect(fixture.owner.isLive && model.outcomes.isEmpty)

        await model.refreshPullRequest()
        #expect(!model.showsPush)
        try write("more", to: "more", in: fixture)
        await model.refreshPullRequest()
        #expect(model.showsPush)
        await model.files.attach(fixture.record)
        #expect(await inspectorHeight(model) > 0)
        await model.pushPullRequestBranch()
        #expect(!model.showsPush && !model.isPushing && model.alertMessage == nil)

        await model.requestDiscard(fixture.record)
        let message = try #require(model.pendingDiscard?.message)
        #expect(
            message.hasSuffix(
                "The remote branch origin/\(try #require(fixture.record.branch)) and any pull request from it are not touched."
            )
        )
        await model.sessions.closeAll()
    }

    @Test func aFailureStaysInTheSheetWithItsStep() async throws {
        let fixture = try await fixture(createFailure: "GraphQL: something went wrong")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        try write("hello", to: "greeting", in: fixture)
        await model.refreshPullRequest()
        model.requestPullRequest()
        let draft = try #require(model.pullRequestDraft)
        draft.title = "Greet"
        await model.confirmPullRequest(draft)
        #expect(model.pullRequestDraft === draft && !draft.isRunning)
        #expect(draft.step == .creating)
        #expect(draft.failure?.contains("something went wrong") == true)
        #expect(model.displayedPullRequest == nil && model.showsMerge && model.showsOpenPullRequest)
        await model.sessions.closeAll()
    }

    @Test func hiddenWithoutARemote() async throws {
        let fixture = try await fixture(gh: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        await model.refreshPullRequest()
        #expect(!model.showsOpenPullRequest && model.showsMerge)
        model.requestPullRequest()
        #expect(model.pullRequestDraft == nil)
        await model.sessions.closeAll()
    }
}
