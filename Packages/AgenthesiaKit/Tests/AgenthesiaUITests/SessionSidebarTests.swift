import AppKit
import Persistence
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite(.serialized) struct SessionSidebarTests {
    @Test func nativeListHighlightsTheSelectedSession() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "sidebar-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        let store = try await sessions.library.store()
        let project = ProjectRecord(name: "Project", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Mock", executable: "unused")
        let first = SessionRecord(
            projectID: project.id,
            agentInstallID: agent.id,
            title: "First",
            workingDirectory: project.rootPath
        )
        let second = SessionRecord(
            projectID: project.id,
            agentInstallID: agent.id,
            title: "Second",
            workingDirectory: project.rootPath
        )
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        try await store.createSession(first)
        try await store.createSession(second)
        let model = SessionWindowModel(sessions: sessions)
        await model.refresh()
        await model.showHistory(first)
        let host = NSHostingView(rootView: RootView(model: model))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { model.close(); window.close() }
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        // The seeded history has sidebar rows and an empty transcript.
        let table = try #require(descendant(in: host))
        try #require(table.selectedRow >= 0)
        let firstRow = table.selectedRow
        await model.showHistory(second)
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        #expect(table.selectedRow >= 0 && table.selectedRow != firstRow)
        table.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
        for _ in 0..<20 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        #expect(model.sidebarSelection == AnyHashable(first.id))
        #expect(model.displayed?.session.id == first.id)
        model.showingSetup = true
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        #expect(table.selectedRowIndexes.isEmpty)
    }

    private func descendant(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.numberOfRows > 0 { return table }
        return view.subviews.lazy.compactMap { descendant(in: $0) }.first
    }
}
