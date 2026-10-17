import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionManagerTests {
    fileprivate func fixture() throws -> (URL, SessionManager) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "session-manager-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SessionManager(
            library: SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite"))
        )
        manager.environment = { (ProcessInfo.processInfo.environment, nil) }
        return (directory, manager)
    }

    fileprivate func mock(arguments: [String] = []) throws -> AgentInstallRecord {
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        return AgentInstallRecord(name: "Mock", executable: binary.path, arguments: arguments)
    }

    @Test func runsSeveralSessionsAndEndsThemOneByOne() async throws {
        let (directory, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = manager.start(directory: directory, agent: try mock())
        let second = manager.start(directory: directory, agent: try mock())
        #expect(manager.owners.map(\.id) == [first.id, second.id])
        #expect(first.isStarting && first.isLive)
        await first.startup?.value
        await second.startup?.value
        let controllers = try [#require(first.controller), #require(second.controller)]
        #expect(controllers.allSatisfy { $0.status == .idle })
        #expect(manager.owner(of: controllers[1].session.id) === second)
        await first.send("one")
        await second.send("two")
        await manager.end(first)
        #expect(manager.owners.map(\.id) == [second.id])
        #expect(!first.isLive && controllers[0].status == .closed)
        #expect(controllers[1].status == .idle)
        #expect(manager.owner(of: controllers[0].session.id) == nil)
        #expect(Set(try await manager.library.history().map(\.id)) == Set(controllers.map(\.session.id)))
        await manager.closeAll()
        #expect(controllers[1].status == .closed)
    }

    @Test func continueSelectsTheLiveOwnerAndReplacesAFailedOne() async throws {
        let (directory, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = manager.start(directory: directory, agent: try mock(arguments: ["--reopen"]))
        await original.startup?.value
        let session = try #require(original.controller?.session)
        await original.send("hello")
        #expect(manager.resume(session) === original)
        await original.send("exit")
        // The failed owner stays listed with its error until it is ended or continued.
        while original.controller?.status != .closed { await Task.yield() }
        #expect(original.errorMessage != nil && !original.isLive)
        #expect(manager.owners.map(\.id) == [original.id])
        #expect(manager.owner(of: session.id) == nil)
        let continued = manager.resume(session)
        // A second Continue during startup finds the starting owner.
        #expect(manager.resume(session) === continued)
        #expect(continued.sessionID == session.id)
        #expect(manager.owners.map(\.id) == [continued.id])
        await continued.startup?.value
        let controller = try #require(continued.controller)
        #expect(original.isClosed)
        #expect(controller.status == .idle)
        await continued.send("again")
        #expect(
            controller.transcript.items.compactMap { $0.message?.text }.suffix(2) == ["again", "Echo: again"]
        )
        #expect(try await manager.library.history().map(\.id) == [session.id])
        await manager.closeAll()
    }

    @Test func closeAllWaitsForAnOwnerStillStarting() async throws {
        let (directory, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = Gate()
        manager.environment = { (await gate.wait(), nil) }
        let owner = manager.start(directory: directory, agent: try mock())
        while !gate.entered { await Task.yield() }
        var closed = false
        let closing = Task {
            await manager.closeAll()
            closed = true
        }
        while !owner.isClosed { await Task.yield() }
        #expect(!closed)
        gate.release()
        await closing.value
        #expect(owner.controller == nil && !owner.isStarting)
        #expect(try await manager.library.history().isEmpty)
    }
}

@MainActor private final class Gate {
    var entered = false
    private var continuation: CheckedContinuation<[String: String], Never>?
    func wait() async -> [String: String] {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: ProcessInfo.processInfo.environment) }
}

extension SessionManagerTests {
    @Test func sessionsStartingTogetherShareOneAgentInstall() async throws {
        let (directory, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = try mock()
        let owners = (0..<4).map { _ in
            manager.start(
                directory: directory,
                agent: AgentInstallRecord(name: agent.name, executable: agent.executable)
            )
        }
        for owner in owners { await owner.startup?.value }
        #expect(owners.allSatisfy { $0.controller != nil && $0.errorMessage == nil })
        #expect(try await manager.library.store().agentInstalls().count == 1)
        #expect(try await manager.library.projects().count == 1)
        await manager.closeAll()
    }
}
