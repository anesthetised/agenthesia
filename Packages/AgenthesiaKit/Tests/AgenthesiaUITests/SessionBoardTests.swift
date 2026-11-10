import ACP
import AppKit
import Foundation
import Persistence
import SwiftUI
import TestSupport
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// The session board and its cards (ADR-0046).
@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionBoardTests {
    @MainActor private struct Fixture {
        let directory: URL
        let sessions: SessionManager
        let model: SessionWindowModel
        let agent: AgentInstallRecord

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "board-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sessions = SessionManager(
                library: SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite"))
            )
            sessions.environment = { (ProcessInfo.processInfo.environment, nil) }
            model = SessionWindowModel(sessions: sessions)
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }
                    .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            agent = AgentInstallRecord(name: "Mock", executable: binary.path)
        }

        func start() async throws -> (LiveSession, SessionController) {
            let owner = sessions.start(directory: directory, agent: agent)
            await owner.startup?.value
            return (owner, try #require(owner.controller))
        }

        func close() async {
            model.close()
            await sessions.closeAll()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private let options: [ACP.PermissionOption] = [
        .init(optionId: "allow", name: "Allow once", kind: .allowOnce),
        .init(optionId: "no", name: "Reject", kind: .rejectOnce),
    ]

    @Test func theGridHoldsOneToThreeColumnsOfAtLeast280Points() {
        #expect(SessionBoard.columnCount(width: 0) == 1)
        #expect(SessionBoard.columnCount(width: 400) == 1)
        #expect(SessionBoard.columnCount(width: 571) == 1)
        #expect(SessionBoard.columnCount(width: 572) == 2)
        #expect(SessionBoard.columnCount(width: 864) == 3)
        #expect(SessionBoard.columnCount(width: 3000) == 3)
    }

    @Test func overviewShowsTheBoardAndASelectionOrNewSessionLeavesIt() async throws {
        let fixture = try Fixture()
        #expect(fixture.model.inDraft && !fixture.model.showingBoard)
        fixture.model.showBoard()
        #expect(fixture.model.showingBoard && !fixture.model.inDraft && !fixture.model.canStartDraft)
        #expect(fixture.model.target == .board && fixture.model.windowTitle == "Overview")
        #expect(fixture.model.sidebarSelection == SessionWindowModel.overviewID)

        let (owner, controller) = try await fixture.start()
        fixture.model.sidebarSelection = SessionWindowModel.NavigationTarget.live(owner).id
        #expect(!fixture.model.showingBoard && fixture.model.displayed === controller)
        #expect(fixture.model.target == .session(controller.session.id))
        fixture.model.sidebarSelection = SessionWindowModel.overviewID
        #expect(fixture.model.showingBoard && fixture.model.displayed == nil)
        // New Session shows the draft, with what was typed in it.
        fixture.model.draft.text = "Kept"
        fixture.model.showingSetup = true
        #expect(fixture.model.inDraft && !fixture.model.showingBoard && fixture.model.draft.text == "Kept")
        // From the board, Next Session selects the first row.
        fixture.model.showBoard()
        #expect(fixture.model.navigationTarget()?.id == SessionWindowModel.NavigationTarget.live(owner).id)
        await fixture.close()
        #expect(fixture.model.target == .launch)
    }

    @Test func aBoardWindowRestoresToTheBoardAndALoneOneFillsInPlace() async throws {
        let fixture = try Fixture()
        let data = try JSONEncoder().encode(WindowTarget.board)
        #expect(try JSONDecoder().decode(WindowTarget.self, from: data) == .board)
        #expect(WindowTarget.board.url == nil)
        await fixture.model.restore(.board)
        #expect(fixture.model.showingBoard)

        let (_, controller) = try await fixture.start()
        let target = WindowTarget.session(controller.session.id)
        var opened: [WindowTarget] = []
        await fixture.model.activate(target, isBlank: false, windowCount: 1) { opened.append($0) }
        #expect(opened.isEmpty && fixture.model.target == target)
        await fixture.close()
    }

    @Test func anEmptyBoardHasNoCards() async throws {
        let fixture = try Fixture()
        #expect(SessionBoard.cards(fixture.model).isEmpty)
        await fixture.close()
    }

    @Test func aCardSaysWhatTheRowSaysAndTheAgentsLastLine() async throws {
        let fixture = try Fixture()
        let (owner, controller) = try await fixture.start()
        await owner.send("hello")
        owner.markSeen()
        await fixture.model.refresh()

        let idle = try #require(SessionBoard.cards(fixture.model).first)
        #expect(idle.id == SessionWindowModel.NavigationTarget.live(owner).id)
        #expect(idle.title == (controller.session.title ?? "New Session"))
        #expect(idle.project == fixture.directory.lastPathComponent)
        #expect(idle.activity == .idle && idle.reason == nil)
        #expect(idle.lastLine == "Echo: hello")
        let last = try #require(idle.lastActivity)
        #expect(idle.time(now: last.addingTimeInterval(20 * 60)) == "Idle 20m")
        #expect(idle.request == nil && idle.choices.isEmpty)

        let turn = Task { await owner.send("slow") }
        await eventually { controller.turnStartedAt != nil }
        let started = try #require(controller.turnStartedAt)
        let working = try #require(SessionBoard.cards(fixture.model).first)
        #expect(working.activity == .working)
        #expect(working.time(now: started.addingTimeInterval(72)) == "Working 1m 12s")
        #expect(
            working.accessibilityLabel(now: started.addingTimeInterval(72)).hasPrefix(
                "\(working.title), \(fixture.directory.lastPathComponent), Working 1m 12s"
            )
        )
        await owner.stop()
        await turn.value
        await fixture.close()
    }

    @Test func aPermissionCardOffersOpenFirstOnlyForARequestWithADiff() async throws {
        let fixture = try Fixture()
        let (owner, controller) = try await fixture.start()
        let turn = Task { await owner.send("slow") }
        await eventually { controller.status == .running }
        let agentID = try #require(controller.session.agentSessionID)

        let command = ACP.ToolCallUpdate(toolCallId: "run", title: "swift test", kind: .execute)
        let commandAnswer = Task { await controller.requestPermission(for: command, options: options, in: agentID) }
        await eventually { !controller.pendingPermissions.isEmpty }
        let asking = try #require(SessionBoard.cards(fixture.model).first)
        #expect(asking.activity == .needsInput && asking.reason == "Allow? swift test")
        #expect(asking.choices == options.map(PermissionChoice.option))
        // The card answers through `answerPermission`, like every other surface.
        let request = try #require(asking.request)
        #expect(asking.session?.answerPermission(request.id, with: "allow") == true)
        #expect(await commandAnswer.value == .selected("allow"))

        let edit = ACP.ToolCallUpdate(
            toolCallId: "edit",
            title: "Update notes",
            kind: .edit,
            content: [.diff(.init(path: "notes.md", oldText: "a", newText: "b"))]
        )
        let editAnswer = Task { await controller.requestPermission(for: edit, options: options, in: agentID) }
        await eventually { !controller.pendingPermissions.isEmpty }
        let editing = try #require(SessionBoard.cards(fixture.model).first)
        #expect(editing.choices == [.open] + options.map(PermissionChoice.option))
        let pending = try #require(editing.request)
        controller.answerPermission(pending.id, with: "no")
        #expect(await editAnswer.value == .selected("no"))

        await owner.stop()
        await turn.value
        await fixture.close()
    }

    /// Hosts `view` in an offscreen window and lets it settle; hosted SwiftUI exposes no accessibility tree to a test
    /// without an assistive client, so these tests read what the view measures.
    private func host<V: View>(_ view: V, in window: OffscreenWindow) async -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        return host
    }

    @Test func aCardGrowsWithTheLastLineAndAPendingRequest() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        let window = OffscreenWindow(size: .init(width: 320, height: 400))
        defer { window.close() }
        let (owner, controller) = try await fixture.start()
        let bare = try #require(SessionBoard.cards(fixture.model).first)
        let bareHeight = await host(SessionCard(content: bare) {}, in: window).fittingSize.height
        #expect(bareHeight > 0)

        await owner.send("hello")
        let said = try #require(SessionBoard.cards(fixture.model).first)
        let saidHeight = await host(SessionCard(content: said) {}, in: window).fittingSize.height
        #expect(saidHeight > bareHeight)

        let turn = Task { await owner.send("slow") }
        await eventually { controller.status == .running }
        let agentID = try #require(controller.session.agentSessionID)
        let call = ACP.ToolCallUpdate(toolCallId: "run", title: "swift test", kind: .execute)
        let answer = Task { await controller.requestPermission(for: call, options: options, in: agentID) }
        await eventually { !controller.pendingPermissions.isEmpty }
        let asking = try #require(SessionBoard.cards(fixture.model).first)
        #expect(await host(SessionCard(content: asking) {}, in: window).fittingSize.height > saidHeight)
        let request = try #require(asking.request)
        controller.answerPermission(request.id, with: "no")
        _ = await answer.value
        await owner.stop()
        await turn.value
        await fixture.close()
    }

    @Test func theBoardShowsNoAgentsRunningOrItsCards() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        let window = OffscreenWindow(size: .init(width: 900, height: 600))
        defer { window.close() }
        fixture.model.showBoard()
        let board = await host(SessionBoard(model: fixture.model), in: window)
        #expect(board.fittingSize.height > 0)
        _ = try await fixture.start()
        _ = try await fixture.start()
        #expect(SessionBoard.cards(fixture.model).count == 2)
        await fixture.close()
    }

    @Test func tabReachesEveryCard() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        for _ in 0..<3 { _ = try await fixture.start() }
        let cards = SessionBoard.cards(fixture.model)
        #expect(cards.count == 3)
        let window = OffscreenWindow(size: .init(width: 400, height: 600))
        defer { window.close() }
        let log = FocusLog()
        let host = NSHostingView(rootView: FocusProbe(cards: cards, log: log))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        // Whether or not keyboard navigation is on, each card is a stop of the window's key view loop.
        for _ in cards {
            window.selectNextKeyView(nil)
            for _ in 0..<10 { await Task.yield() }
        }
        #expect(Set(log.focused) == Set(cards.map(\.id)))
        await fixture.close()
    }
}

/// The cards the board would show, with the one that has keyboard focus reported to `log`.
@MainActor private final class FocusLog { var focused: [AnyHashable] = [] }

private struct FocusProbe: View {
    let cards: [SessionCard.Content]
    let log: FocusLog
    @FocusState private var focused: AnyHashable?

    var body: some View {
        VStack {
            ForEach(cards) { card in
                SessionCard(content: card) {}.focused($focused, equals: card.id)
            }
        }
        .onChange(of: focused) { if let focused { log.focused.append(focused) } }
    }
}
