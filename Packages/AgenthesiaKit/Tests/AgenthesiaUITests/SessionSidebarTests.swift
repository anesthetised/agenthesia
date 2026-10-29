import AppKit
import Persistence
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SessionSidebarTests {
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
            contentRect: .init(x: 0, y: 0, width: 1600, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { model.close(); window.close() }
        // The footer list takes a second pass to measure its height cap.
        for _ in 0..<30 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        // The seeded history is the Settled footer's list of two rows; the top list holds the changed files.
        let table = try #require(descendant(in: host) { $0.numberOfRows == 2 })
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
        // Nothing is selected any more, so the Settled footer closes and its list leaves the window.
        #expect(table.window == nil)
    }

    @Test func continueAfterProcessExitUsesHistoryRefreshedAfterStartup() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "sidebar-startup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        sessions.environment = { (ProcessInfo.processInfo.environment, nil) }
        let model = SessionWindowModel(sessions: sessions)
        let host = NSHostingView(rootView: RootView(model: model))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1600, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        let gate = SessionPersistenceGate()
        defer { gate.release(); model.close(); window.close() }
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        model.start(directory: directory, executable: binary.path, arguments: ["--reopen"])
        let owner = try #require(model.owner)
        while owner.controller == nil && owner.isStarting { await Task.yield() }
        let controller = try #require(owner.controller)
        let create = controller.createSession
        controller.createSession = { record in
            await gate.wait()
            try await create(record)
        }
        while !gate.entered, owner.isStarting { await Task.yield() }
        try #require(gate.entered)
        // The ID already exists, but the database insert has not happened yet.
        await model.refresh()
        #expect(model.history.isEmpty)
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        gate.release()
        await owner.startup?.value
        let deadline = ContinuousClock.now + .seconds(2)
        while !model.history.contains(where: { $0.id == controller.session.id }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        #expect(model.history.contains { $0.id == controller.session.id })
        await owner.send("exit")
        while controller.status != .closed { await Task.yield() }
        #expect(model.canContinue)
        if model.canContinue {
            model.continueRestored()
            let continuing = try #require(model.owner)
            await continuing.startup?.value
            #expect(continuing !== owner)
            let resumed = try #require(continuing.controller)
            #expect(resumed.status == .idle && !resumed.queuePaused)
            #expect(continuing.sessionID == controller.session.id)
            try await resumed.submit([.init(text: "fresh after Continue")])
            #expect(resumed.queuedPrompts.isEmpty)
            while resumed.status == .running { await Task.yield() }
            #expect(resumed.transcript.items.compactMap(\.message).last?.text == "Echo: fresh after Continue")
        }
        await sessions.closeAll()
    }

    private func descendant(in view: NSView, where matches: (NSTableView) -> Bool) -> NSTableView? {
        if let table = view as? NSTableView, matches(table) { return table }
        for subview in view.subviews { if let found = descendant(in: subview, where: matches) { return found } }
        return nil
    }
}

@MainActor private final class SessionPersistenceGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WindowRestorationTests {
    private final class Box { var value: WindowTarget; init(_ value: WindowTarget) { self.value = value } }

    /// Wide enough for the sidebar, the transcript and the inspector: a narrower window than the content's minimum
    /// makes AppKit repeat constraint passes until it throws.
    private func host(_ model: SessionWindowModel, _ box: Box) -> (NSHostingView<RootView>, NSWindow) {
        _ = NSApplication.shared
        let binding = Binding(get: { box.value }, set: { box.value = $0 })
        let host = NSHostingView(rootView: RootView(model: model, target: binding))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1600, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return (host, window)
    }

    private func settle(_ host: NSView) async { for _ in 0..<30 { await Task.yield(); host.layoutSubtreeIfNeeded() } }

    @Test func restoredWindowShowsItsSessionAndPublishesSelectionChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "restore-\(UUID())")
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
            workingDirectory: project.rootPath
        )
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        try await store.createSession(record)

        let model = SessionWindowModel(sessions: sessions)
        let box = Box(.session(record.id))
        let (host, window) = host(model, box)
        defer { model.close(); window.close() }
        await settle(host)
        #expect(model.displayed?.status == .readOnly && model.canContinue)
        #expect(box.value == .session(record.id))
        model.showingSetup = true
        await settle(host)
        #expect(box.value == .launch)

        let stale = SessionWindowModel(sessions: sessions)
        let staleBox = Box(.session(UUID()))
        let (staleHost, staleWindow) = self.host(stale, staleBox)
        defer { stale.close(); staleWindow.close() }
        await settle(staleHost)
        #expect(stale.showingSetup && staleBox.value == .launch)
    }
}
