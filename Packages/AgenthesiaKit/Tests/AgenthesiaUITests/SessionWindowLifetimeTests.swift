import AppKit
import Persistence
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SessionWindowLifetimeTests {
    @Test func closingNativeWindowKeepsOwnerRegisteredUntilCleanupFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-lifetime-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = SessionWindowModel(
            library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
        )
        let owner = LiveSession(library: model.library)
        model.owner = owner
        let gate = StartupGate()
        defer { gate.release() }
        owner.environment = { (await gate.wait(), nil) }
        let start = Task {
            await owner.start(directory: directory, agent: AgentInstallRecord(name: "Test", executable: "/bin/sh"))
        }
        while !gate.entered { await Task.yield() }
        let window = host(model)
        defer { SessionApplicationDelegate.windows.removeValue(forKey: model.id) }
        #expect(SessionApplicationDelegate.windows[model.id] === model)
        window.close()
        while !owner.isClosed { await Task.yield() }
        #expect(model.closed)
        #expect(SessionApplicationDelegate.windows[model.id] === model)
        gate.release()
        await start.value
        while SessionApplicationDelegate.windows[model.id] != nil { await Task.yield() }
        #expect(owner.controller == nil)
    }

    @Test(arguments: [false, true])
    func quittingWaitsForAllWindowsIncludingPendingWindowClose(closeWindowFirst: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-lifetime-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
        let models = [SessionWindowModel(library: library), SessionWindowModel(library: library)]
        let owner = LiveSession(library: library)
        models[0].owner = owner
        let gate = StartupGate()
        defer { gate.release() }
        owner.environment = { (await gate.wait(), nil) }
        let start = Task {
            await owner.start(directory: directory, agent: AgentInstallRecord(name: "Test", executable: "/bin/sh"))
        }
        while !gate.entered { await Task.yield() }
        let windows = models.map(host)
        defer {
            for window in windows { window.close() }
            for model in models { SessionApplicationDelegate.windows.removeValue(forKey: model.id) }
        }
        let delegate = SessionApplicationDelegate()
        var replies = 0
        delegate.terminationReply = { _ in
            #expect(models.allSatisfy { $0.closed })
            #expect(!owner.isStarting)
            replies += 1
        }
        if closeWindowFirst {
            windows[0].close()
            while !owner.isClosed { await Task.yield() }
        }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        while !owner.isClosed { await Task.yield() }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(replies == 0)
        gate.release()
        await start.value
        while replies == 0 { await Task.yield() }
        #expect(replies == 1)
        #expect(owner.controller == nil)
        for window in windows { window.close() }
        while models.contains(where: { SessionApplicationDelegate.windows[$0.id] != nil }) { await Task.yield() }
    }

    @Test(arguments: [false, true]) func closingOrQuittingSettlesAPendingPermission(quit: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-permission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = SessionWindowModel(
            library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
        )
        let owner = LiveSession(library: model.library)
        model.owner = owner
        owner.environment = { (ProcessInfo.processInfo.environment, nil) }
        await owner.start(directory: directory, agent: try mockAgent())
        let controller = try #require(owner.controller)
        let turn = Task { await owner.send("write \(directory.appending(path: "unwritten.txt").path) text") }
        while controller.pendingPermissions.isEmpty { await Task.yield() }
        let request = controller.pendingPermissions[0]
        let window = host(model)
        defer { SessionApplicationDelegate.windows.removeValue(forKey: model.id) }
        if quit {
            let delegate = SessionApplicationDelegate()
            var replies = 0
            delegate.terminationReply = { _ in replies += 1 }
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
            while replies == 0 { await Task.yield() }
        } else {
            window.close()
            while SessionApplicationDelegate.windows[model.id] != nil { await Task.yield() }
        }
        await turn.value
        #expect(controller.status == .closed)
        #expect(controller.pendingPermissions.isEmpty)
        #expect(controller.transcript.items.compactMap(\.permission).map(\.outcome) == [.cancelled])
        // A click that arrives after shutdown is stale.
        #expect(!controller.answerPermission(request.id, with: "allow"))
        window.close()
    }

    @Test func quittingWithoutWindowsIsImmediate() {
        #expect(SessionApplicationDelegate.windows.isEmpty)
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
