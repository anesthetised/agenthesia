import AppKit
import Persistence
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SidebarShelvesTests {
    @Test func labelNamesTheSectionTheCountAndTheState() {
        #expect(
            SidebarShelves.accessibilityLabel(.settled, count: 1, expanded: false) == "Settled, 1 session, collapsed"
        )
        #expect(
            SidebarShelves.accessibilityLabel(.settled, count: 12, expanded: true) == "Settled, 12 sessions, expanded"
        )
        #expect(
            SidebarShelves.accessibilityLabel(.working, count: 2, expanded: true) == "Working, 2 sessions, expanded"
        )
    }

    @Test func listHeightFollowsTheRowsUpToTheCap() {
        #expect(
            SidebarShelves.listHeight(rows: 2, cap: 270) == 2 * SidebarShelves.rowHeight + SidebarShelves.listPadding
        )
        #expect(SidebarShelves.listHeight(rows: 100, cap: 270) == 270)
    }

    @Test func aShelfIsOpenWhenAskedOrWhileASearchShowsItsMatches() {
        #expect(SidebarShelves.isOpen(stored: true, filtered: false))
        #expect(!SidebarShelves.isOpen(stored: false, filtered: false))
        #expect(SidebarShelves.isOpen(stored: false, filtered: true))
    }

    @Test func shelvesAnimateUnlessReduceMotionIsOn() {
        #expect(SidebarShelves.animation(reduceMotion: false) != nil)
        #expect(SidebarShelves.animation(reduceMotion: true) == nil)
    }

    private func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

    @Test func workingTakesItsShareAndSettledLeavesTheTopListRoom() {
        // A tall sidebar: each shelf has its full share.
        let tall = SidebarShelves.listHeights(height: 1000, working: 100, settled: 100)
        #expect(close(tall.working, 1000 * SidebarShelves.workingShare))
        #expect(close(tall.settled, 1000 * SidebarShelves.settledShare))
        // A short one: Settled gives way, so the headers and the list above keep their room.
        let short = SidebarShelves.listHeights(height: 400, working: 100, settled: 100)
        #expect(close(short.working, 400 * SidebarShelves.workingShare))
        #expect(abs(400 - short.working - short.settled - SidebarShelves.topRoom) < 0.001)
        // A closed or short Working shelf leaves Settled its share; a closed shelf has no list.
        #expect(
            close(
                SidebarShelves.listHeights(height: 400, working: nil, settled: 100).settled,
                400 * SidebarShelves.settledShare
            )
        )
        let few = SidebarShelves.listHeights(height: 400, working: 1, settled: nil)
        #expect(few.working == SidebarShelves.rowHeight + SidebarShelves.listPadding && few.settled == 0)
        // Before the sidebar is measured, nothing goes negative.
        let unmeasured = SidebarShelves.listHeights(height: 0, working: 3, settled: 3)
        #expect(unmeasured.working == 0 && unmeasured.settled == 0)
    }

    @Test func footerIsHiddenWithoutSettledSessions() async throws {
        let fixture = try await Fixture(sessions: 0)
        defer { fixture.close() }
        await fixture.settle()
        // The list reserves no room for a header (the collapsed footer reserves more than 20 pt; the system's own
        // bottom padding differs between macOS versions) and there is no second list.
        #expect(fixture.sidebarTables().count == 1)
        #expect(fixture.bottomInset() < 20)
    }

    @Test func footerIsCollapsedByDefaultAndKeepsItsHeaderAtTheBottomEdge() async throws {
        let fixture = try await Fixture(sessions: 3)
        defer { fixture.close() }
        await fixture.settle()
        // Only the header: the list above reserves room for it and the footer has no list of its own.
        #expect(fixture.sidebarTables().count == 1)
        #expect(fixture.bottomInset() > 20 && fixture.bottomInset() < 50)
    }

    @Test func anExpandedSettledShelfStaysWithinItsCap() async throws {
        let fixture = try await Fixture(sessions: 40)
        defer { fixture.close() }
        await fixture.settle()
        fixture.model.settledShelfExpanded = true
        await fixture.model.showHistory(fixture.records[0])
        await fixture.settle()
        let tables = fixture.sidebarTables()
        try #require(tables.count == 2)
        let list = try #require(tables.last?.enclosingScrollView)
        let cap = fixture.host.bounds.height * SidebarShelves.settledShare
        // The share is of the sidebar below the search field, which is shorter than the window by a version-dependent
        // amount, so the list is a little under the cap and still well above a third of the window.
        #expect(list.frame.height < cap + 12 && list.frame.height > fixture.host.bounds.height * 0.35)
    }

    @Test func fewSettledSessionsShrinkTheFooterToTheirRows() async throws {
        let fixture = try await Fixture(sessions: 2)
        defer { fixture.close() }
        await fixture.settle()
        fixture.model.settledShelfExpanded = true
        await fixture.model.showHistory(fixture.records[0])
        await fixture.settle()
        let table = try #require(fixture.sidebarTables().last)
        let list = try #require(table.enclosingScrollView)
        #expect(table.numberOfRows == 2)
        // The estimate holds: the list is about as tall as its rows, so it hardly scrolls and has no empty space.
        #expect(list.frame.height < fixture.host.bounds.height * SidebarShelves.settledShare)
        #expect(abs(list.frame.height - table.frame.height) < 12)
    }

    @Test func settledCollapsesWhileOneOfItsRowsIsSelected() async throws {
        let fixture = try await Fixture(sessions: 2)
        defer { fixture.close() }
        await fixture.settle()
        fixture.model.settledShelfExpanded = true
        await fixture.model.showHistory(fixture.records[0])
        await fixture.settle()
        #expect(fixture.sidebarTables().count == 2)
        fixture.model.settledShelfExpanded = false
        // The list leaves with the shelf's animation.
        for _ in 0..<40 where fixture.sidebarTables().count != 1 {
            try await Task.sleep(for: .milliseconds(50))
            await fixture.settle()
        }
        #expect(fixture.sidebarTables().count == 1)
        // The selection and the session in the detail column stay.
        #expect(fixture.model.sidebarSelection == AnyHashable(fixture.records[0].id))
        #expect(fixture.model.displayed?.session.id == fixture.records[0].id)
    }

    @Test func nextSessionExpandsTheCollapsedShelfItMovesInto() async throws {
        let fixture = try await Fixture(sessions: 3)
        defer { fixture.close() }
        await fixture.settle()
        fixture.model.showingSetup = true
        fixture.model.settledShelfExpanded = false
        await fixture.model.navigate()
        #expect(fixture.model.settledShelfExpanded)
        #expect(fixture.model.sidebarSelection != nil)
        await fixture.settle()
        #expect(fixture.sidebarTables().count == 2)
    }

    @Test func nextSessionExpandsACollapsedWorkingShelfAndLeavesSettledAlone() async throws {
        let fixture = try await Fixture(sessions: 2, live: 1)
        defer { fixture.close() }
        await fixture.settle()
        fixture.model.showingSetup = true
        fixture.model.workingShelfExpanded = false
        await fixture.model.navigate()
        #expect(fixture.model.workingShelfExpanded)
        #expect(!fixture.model.settledShelfExpanded)
        await fixture.manager.closeAll()
    }

    @Test func searchOpensTheFooterOnItsMatchesAndEmptyResultsHideIt() async throws {
        let fixture = try await Fixture(sessions: 12)
        defer { fixture.close() }
        await fixture.settle()
        #expect(fixture.sidebarTables().count == 1)
        // "Session 1" matches 1, 10 and 11; nothing is selected, yet the footer lists them.
        fixture.model.sidebarQuery = "session 1"
        await fixture.settle()
        let tables = fixture.sidebarTables()
        try #require(tables.count == 2)
        #expect(tables.last?.numberOfRows == 3)
        fixture.model.sidebarQuery = "nothing"
        await fixture.settle()
        #expect(fixture.sidebarTables().count == 1)
        #expect(fixture.bottomInset() < 20)
        fixture.model.sidebarQuery = ""
        await fixture.settle()
        #expect(fixture.sidebarTables().count == 1)
    }

    @Test func anIdleSessionSitsOnTheWorkingShelfExpandedByDefault() async throws {
        let fixture = try await Fixture(sessions: 0, live: 1)
        defer { fixture.close() }
        // The draft selects no row, so the shelf is open by default rather than forced open by the selection.
        fixture.model.showingSetup = true
        await fixture.settle()
        let tables = fixture.sidebarTables()
        try #require(tables.count == 2)
        // The top list holds the Overview row and Needs You, which is empty; the shelf lists the session under it.
        #expect(tables[0].numberOfRows == 1)
        #expect(tables[1].numberOfRows == 1)
        let list = try #require(tables[1].enclosingScrollView)
        #expect(abs(list.frame.height - (SidebarShelves.rowHeight + SidebarShelves.listPadding)) < 2)
        await fixture.manager.closeAll()
    }

    @Test func theWorkingShelfSitsAboveSettled() async throws {
        let fixture = try await Fixture(sessions: 40, live: 1)
        defer { fixture.close() }
        await fixture.settle()
        fixture.model.settledShelfExpanded = true
        await fixture.model.showHistory(fixture.records[0])
        await fixture.settle()
        let tables = fixture.sidebarTables()
        try #require(tables.count == 3)
        #expect(tables[1].numberOfRows == 1 && tables[2].numberOfRows == 40)
        let settled = try #require(tables[2].enclosingScrollView)
        #expect(settled.frame.height < fixture.host.bounds.height * SidebarShelves.settledShare + 12)
        // Previous and Next Session follow the shelves' order: the live session comes before Settled.
        fixture.model.showingSetup = true
        #expect(fixture.model.navigationTarget()?.id == fixture.model.sidebar.section(.working)?.rows.first?.id)
        await fixture.manager.closeAll()
    }
}

@MainActor private struct Fixture {
    let directory: URL
    let manager: SessionManager
    let model: SessionWindowModel
    let host: NSHostingView<RootView>
    let window: NSWindow
    let records: [SessionRecord]

    /// `live` sessions of the bundled `MockAgent` are started and left idle; the caller closes them.
    init(sessions count: Int, live: Int = 0) async throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appending(path: "settled-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        manager.environment = { (ProcessInfo.processInfo.environment, nil) }
        self.manager = manager
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
        if live > 0 {
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            for _ in 0..<live {
                let owner = try #require(
                    model.start(directory: directory, agent: .init(name: "Mock", executable: binary.path))
                )
                await owner.startup?.value
            }
        }
        host = NSHostingView(rootView: RootView(model: model))
        window = OffscreenWindow(size: .init(width: 900, height: 600))
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
