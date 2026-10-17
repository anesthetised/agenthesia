import AppKit
import Persistence
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SessionWindowLifetimeTests {
    private func delegate(_ directory: URL) -> SessionApplicationDelegate {
        let delegate = SessionApplicationDelegate()
        delegate.sessions = SessionManager(
            library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
        )
        delegate.confirmQuit = { _ in true }
        delegate.sessions.environment = { (ProcessInfo.processInfo.environment, nil) }
        return delegate
    }

    @Test func closingNativeWindowDetachesWithoutEndingItsSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-lifetime-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = delegate(directory).sessions
        let model = SessionWindowModel(sessions: sessions)
        model.start(directory: directory, executable: try mockAgent().executable, arguments: [])
        let owner = try #require(model.owner)
        await owner.startup?.value
        let window = host(model)
        window.close()
        #expect(model.closed)
        #expect(owner.isLive && owner.controller?.status == .idle)
        #expect(sessions.owners.map(\.id) == [owner.id])
        await sessions.closeAll()
    }

    @Test func quittingWaitsForEveryOwnerIncludingOneStillStarting() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-lifetime-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = delegate(directory)
        let running = delegate.sessions.start(directory: directory, agent: try mockAgent())
        await running.startup?.value
        let gate = StartupGate()
        defer { gate.release() }
        delegate.confirmQuit = { _ in true }
        delegate.sessions.environment = { (await gate.wait(), nil) }
        let starting = delegate.sessions.start(directory: directory, agent: try mockAgent())
        while !gate.entered { await Task.yield() }
        var replies = 0
        delegate.terminationReply = { _ in
            #expect(!starting.isStarting)
            replies += 1
        }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        while !starting.isClosed { await Task.yield() }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(replies == 0)
        gate.release()
        while replies == 0 { await Task.yield() }
        #expect(replies == 1)
        #expect(starting.controller == nil)
        #expect(running.controller?.status == .closed)
    }

    @Test func quittingSettlesAPendingPermissionThatClosingTheWindowKeeps() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-permission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = delegate(directory)
        let model = SessionWindowModel(sessions: delegate.sessions)
        model.start(directory: directory, executable: try mockAgent().executable, arguments: [])
        let owner = try #require(model.owner)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        let turn = Task { await owner.send("write \(directory.appending(path: "unwritten.txt").path) text") }
        while controller.pendingPermissions.isEmpty { await Task.yield() }
        let request = controller.pendingPermissions[0]
        var confirmedCount = 0
        delegate.confirmQuit = {
            confirmedCount = $0; return true
        }
        host(model).close()
        #expect(controller.pendingPermissions.map(\.id) == [request.id])
        var replies = 0
        delegate.terminationReply = { _ in replies += 1 }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        while replies == 0 { await Task.yield() }
        await turn.value
        #expect(confirmedCount == 1)
        #expect(controller.status == .closed)
        #expect(controller.pendingPermissions.isEmpty)
        #expect(controller.transcript.items.compactMap(\.permission).map(\.outcome) == [.cancelled])
        // A click that arrives after shutdown is stale.
        #expect(!controller.answerPermission(request.id, with: "allow"))
    }

    @Test func cancellingQuitKeepsStartingOwnersAndAllowsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "quit-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = delegate(directory)
        let gate = StartupGate()
        defer { gate.release() }
        delegate.sessions.environment = { (await gate.wait(), nil) }
        let owner = delegate.sessions.start(directory: directory, agent: try mockAgent())
        while !gate.entered { await Task.yield() }
        var counts: [Int] = []
        delegate.confirmQuit = {
            counts.append($0); return false
        }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(counts == [1])
        #expect(!owner.isClosed)
        var replied = false
        delegate.confirmQuit = {
            counts.append($0); return true
        }
        delegate.terminationReply = { _ in replied = true }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        gate.release()
        while !replied { await Task.yield() }
        #expect(counts == [1, 1])
        #expect(owner.isClosed)
    }

    @Test func quitCountsWorkingOwnersAndExcludesIdleOwners() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "quit-count-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = delegate(directory)
        let idle = delegate.sessions.start(directory: directory, agent: try mockAgent())
        await idle.startup?.value
        let first = StartupGate(), second = StartupGate()
        delegate.sessions.environment = { (await first.wait(), nil) }
        let one = delegate.sessions.start(directory: directory, agent: try mockAgent())
        while !first.entered { await Task.yield() }
        delegate.sessions.environment = { (await second.wait(), nil) }
        let two = delegate.sessions.start(directory: directory, agent: try mockAgent())
        while !second.entered { await Task.yield() }
        var count = 0
        delegate.confirmQuit = {
            count = $0; return false
        }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(count == 2)
        #expect(!one.isClosed && !two.isClosed && idle.isLive)
        first.release(); second.release()
        await delegate.sessions.closeAll()
    }

    @Test func idleAndFailedOwnersDoNotAskForQuitConfirmation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "quit-idle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = delegate(directory)
        let idle = delegate.sessions.start(directory: directory, agent: try mockAgent())
        let failed = delegate.sessions.start(
            directory: directory,
            agent: AgentInstallRecord(name: "Missing", executable: "/missing-agent")
        )
        await idle.startup?.value
        await failed.startup?.value
        #expect(idle.activity == .idle && failed.activity == .failed)
        delegate.confirmQuit = { _ in
            Issue.record("Idle and failed owners need no confirmation"); return false
        }
        var replied = false
        delegate.terminationReply = { _ in replied = true }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        while !replied { await Task.yield() }
        #expect(idle.isClosed && failed.isClosed)
    }

    @Test func quittingWithoutSessionsIsImmediate() {
        let delegate = SessionApplicationDelegate()
        delegate.terminationReply = { _ in Issue.record("No asynchronous termination reply is needed") }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    private func host(_ model: SessionWindowModel) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = SessionWindowLifetime.View()
        view.model = model
        window.contentView = view
        return window
    }
}

private func mockAgent() throws -> AgentInstallRecord {
    let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
    let binary = try #require(
        [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
            .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    )
    return AgentInstallRecord(name: "Mock", executable: binary.path)
}

@MainActor private final class StartupGate {
    var entered = false
    private var continuation: CheckedContinuation<[String: String], Never>?

    func wait() async -> [String: String] {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume(returning: ProcessInfo.processInfo.environment)
        continuation = nil
    }
}
