import AgenthesiaCore
import AppKit
import Persistence
import SwiftUI
import Testing

@testable import AgenthesiaUI

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ContinueCardTests {
    private typealias State = ContinueCard.State

    private func state(
        _ status: SessionController.Status,
        merging: Bool = false,
        outcome: WorktreeOutcome? = nil,
        canContinue: Bool = false
    ) -> State? {
        State(status: status, isMerging: merging, outcome: outcome, canContinue: canContinue)
    }

    @Test func sessionsThatTakePromptsKeepTheComposer() {
        for status in [SessionController.Status.idle, .running, .stopping] { #expect(state(status) == nil) }
    }

    @Test func eachStateNamesItself() {
        #expect(state(.readOnly)?.title == "Saved session")
        #expect(state(.closed)?.title == "Session ended")
        #expect(state(.failed)?.title == "Connection failed")
        #expect(state(.starting)?.title == "Starting…" && state(.ready)?.title == "Starting…")
        #expect(state(.idle, merging: true)?.title == "Merging…")
        #expect(state(.closed, outcome: .discarded)?.title == "Discarded · read-only")
        #expect(state(.readOnly, outcome: .merged(commit: "abcdef0123", into: "main"))?.title == "Merged · read-only")
    }

    @Test func outcomesWinOverTheStatusAndMerging() {
        let merged = WorktreeOutcome.merged(commit: "abc", into: "main")
        #expect(state(.idle, merging: true, outcome: merged)?.title == "Merged · read-only")
        #expect(state(.readOnly, merging: true)?.title == "Merging…")
    }

    @Test func continueShowsOnlyWithoutAnOutcomeWhenTheSessionCanContinue() {
        #expect(state(.readOnly, canContinue: true)?.showsContinue == true)
        #expect(state(.failed, canContinue: true)?.showsContinue == true)
        #expect(state(.closed, canContinue: true)?.showsContinue == true)
        #expect(state(.readOnly, canContinue: false)?.showsContinue == false)
        #expect(state(.readOnly, outcome: .discarded, canContinue: true)?.showsContinue == false)
        #expect(state(.idle, merging: true, canContinue: false)?.showsContinue == false)
    }

    @Test func everyStateHasASymbol() {
        for status in [SessionController.Status.ready, .starting, .readOnly, .failed, .closed] {
            #expect(
                state(status).map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil } == true
            )
        }
        for outcome in [WorktreeOutcome.discarded, .merged(commit: "abc", into: "main")] {
            #expect(
                state(.closed, outcome: outcome).map {
                    NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil
                } == true
            )
        }
        #expect(
            state(.idle, merging: true).map {
                NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil
            } == true
        )
    }

    @Test func clickingContinueCallsBackAndTheCardHidesItWhenUnavailable() async throws {
        var continued = 0
        // The button sits at the card's trailing edge.
        try await click(
            ContinueCard(state: try #require(state(.readOnly, canContinue: true)), onContinue: { continued += 1 })
        )
        #expect(continued == 1)
        try await click(ContinueCard(state: try #require(state(.readOnly)), onContinue: { continued += 1 }))
        #expect(continued == 1)
    }

    @Test func savedSessionShowsTheCardInsteadOfTheComposer() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "continue-card-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        let store = try await sessions.library.store()
        let project = ProjectRecord(name: "Project", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Mock", executable: "unused")
        let record = SessionRecord(
            projectID: project.id,
            agentInstallID: agent.id,
            agentSessionID: "saved",
            title: "Saved",
            workingDirectory: project.rootPath
        )
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        try await store.createSession(record)
        let model = SessionWindowModel(sessions: sessions)
        await model.refresh()
        await model.showHistory(record)
        let host = NSHostingView(rootView: RootView(model: model))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { model.close(); window.close() }
        for _ in 0..<30 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        #expect(model.canContinue)
        // The composer's editor is gone; the card offers Continue.
        #expect(views(NSTextView.self, in: host).filter(\.isEditable).isEmpty)
        #expect(model.displayed?.status == .readOnly)
    }

    private func click(_ card: ContinueCard) async throws {
        let host = NSHostingView(rootView: card)
        host.frame = .init(x: 0, y: 0, width: 400, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        let point = host.convert(NSPoint(x: host.bounds.maxX - 60, y: host.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
            window.sendEvent(event)
            await Task.yield()
        }
    }

    private func views<V: NSView>(_ type: V.Type, in root: NSView) -> [V] {
        ((root as? V).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }
}
