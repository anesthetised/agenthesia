import AppKit
import Persistence
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SettledFooterTests {
    @Test func labelNamesTheCountAndTheState() {
        #expect(SettledFooter.accessibilityLabel(count: 1, expanded: false) == "Settled, 1 session, collapsed")
        #expect(SettledFooter.accessibilityLabel(count: 12, expanded: true) == "Settled, 12 sessions, expanded")
    }

    @Test func listHeightFollowsTheRowsUpToTheCap() {
        #expect(SettledFooter.listHeight(rows: 2, cap: 270) == 2 * SettledFooter.rowHeight + SettledFooter.listPadding)
        #expect(SettledFooter.listHeight(rows: 100, cap: 270) == 270)
    }

    @Test func footerIsHiddenWithoutSettledSessions() async throws {
        let fixture = try await Fixture(sessions: 0)
        defer { fixture.close() }
        await fixture.settle()
        // The list reserves no room at the bottom edge and there is no second list.
        #expect(fixture.sidebarTables().count == 1)
        #expect(fixture.bottomInset() < 1)
    }

    @Test func footerIsCollapsedByDefaultAndKeepsItsHeaderAtTheBottomEdge() async throws {
        let fixture = try await Fixture(sessions: 3)
        defer { fixture.close() }
        await fixture.settle()
        // Only the header: the list above reserves room for it and the footer has no list of its own.
        #expect(fixture.sidebarTables().count == 1)
        #expect(fixture.bottomInset() > 20 && fixture.bottomInset() < 50)
    }

    @Test func selectingASettledSessionOpensTheFooterWithinItsCap() async throws {
        let fixture = try await Fixture(sessions: 40)
        defer { fixture.close() }
        await fixture.model.showHistory(fixture.records[0])
        await fixture.settle()
        let tables = fixture.sidebarTables()
        try #require(tables.count == 2)
        let list = try #require(tables.last?.enclosingScrollView)
        let cap = fixture.host.bounds.height * SettledFooter.maxShare
        #expect(abs(list.frame.height - cap) < 1)
    }

    @Test func fewSettledSessionsShrinkTheFooterToTheirRows() async throws {
        let fixture = try await Fixture(sessions: 2)
        defer { fixture.close() }
        await fixture.model.showHistory(fixture.records[0])
        await fixture.settle()
        let table = try #require(fixture.sidebarTables().last)
        let list = try #require(table.enclosingScrollView)
        #expect(table.numberOfRows == 2)
        // The estimate holds: the list is about as tall as its rows, so it hardly scrolls and has no empty space.
        #expect(list.frame.height < fixture.host.bounds.height * SettledFooter.maxShare)
        #expect(abs(list.frame.height - table.frame.height) < 12)
    }

    @Test func footerClosesAgainWhenTheSettledSelectionIsCleared() async throws {
        let fixture = try await Fixture(sessions: 2)
        defer { fixture.close() }
        await fixture.model.showHistory(fixture.records[0])
        await fixture.settle()
        #expect(fixture.sidebarTables().count == 2)
        fixture.model.showingSetup = true
        await fixture.settle()
        #expect(fixture.sidebarTables().count == 1)
    }
}

@MainActor private struct Fixture {
    let directory: URL
    let model: SessionWindowModel
    let host: NSHostingView<RootView>
    let window: NSWindow
    let records: [SessionRecord]

    init(sessions count: Int) async throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appending(path: "settled-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        let store = try await manager.library.store()
        let project = ProjectRecord(name: "Project", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Mock", executable: "unused")
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        var records: [SessionRecord] = []
        for index in 0..<count {
            let record = SessionRecord(
                projectID: project.id,
                agentInstallID: agent.id,
                title: "Session \(index)",
                workingDirectory: project.rootPath
            )
            try await store.createSession(record)
            records.append(record)
        }
        self.records = records
        model = SessionWindowModel(sessions: manager)
        await model.refresh()
        host = NSHostingView(rootView: RootView(model: model))
        window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
    }

    func settle() async { for _ in 0..<30 { await Task.yield(); host.layoutSubtreeIfNeeded() } }

    func close() {
        model.close()
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The sidebar's lists (the transcript has its own table).
    func sidebarTables() -> [NSTableView] {
        tableViews(in: host).filter { String(describing: type(of: $0)).contains("ListView") }
            .sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
    }

    /// How far above the window's bottom edge the top list's visible rows end.
    func bottomInset() -> CGFloat { sidebarTables().first.map { $0.convert($0.bounds, to: nil).minY } ?? 0 }

    private func tableViews(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tableViews(in:))
    }
}
