import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// Settle Session, Unsettle Session and the rule in a window (ADR-0050).
@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionSettleWindowTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "window-settled-\(UUID())")

    private func manager() throws -> SessionManager {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
        manager.environment = { (ProcessInfo.processInfo.environment, nil) }
        return manager
    }

    private func mock() throws -> AgentInstallRecord {
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        return AgentInstallRecord(name: "Mock", executable: binary.path, arguments: ["--reopen"])
    }

    /// A saved session that ended without being settled, shown in the window.
    private func savedSession(in model: SessionWindowModel) async throws -> SessionRecord {
        model.start(directory: directory, executable: try mock().executable, arguments: ["--reopen"])
        let owner = try #require(model.owner)
        await owner.startup?.value
        let id = try #require(owner.sessionID)
        await model.sessions.end(owner)
        await model.refresh()
        let record = try #require(model.history.first { $0.id == id })
        await model.showHistory(record)
        return record
    }

    private func settledAt(_ id: UUID, _ sessions: SessionManager) async throws -> Date? {
        try await sessions.library.store().session(id: id)?.settledAt
    }

    @Test func continueAfterSettlingTheShownSessionLeavesItUnsettled() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = try manager()
        let model = SessionWindowModel(sessions: sessions)
        let record = try await savedSession(in: model)
        #expect(model.settleCommandTitle == "Settle Session" && model.toolbarSettle?.title == "Settle Session")
        // ⇧⌘E settles it; the transcript on screen still holds the record loaded before.
        await model.toggleSettled()
        #expect(try await settledAt(record.id, sessions) != nil)
        #expect(model.displayed?.session.settledAt == nil)
        #expect(model.settleCommandTitle == "Unsettle Session" && model.toolbarSettle == nil)
        model.continueRestored()
        let owner = try #require(model.owner)
        await owner.startup?.value
        #expect(owner.isLive)
        #expect(try await settledAt(record.id, sessions) == nil)
        await sessions.closeAll()
    }

    @Test func theMenuTogglesTheShownSavedSessionWhileAnotherOwnerStarts() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = try manager()
        let model = SessionWindowModel(sessions: sessions)
        let record = try await savedSession(in: model)
        // Another session starts in the same window's owner slot while the saved one is shown.
        let gate = Gate()
        sessions.environment = { (await gate.wait(), nil) }
        let starting = sessions.start(directory: directory, agent: try mock())
        model.owner = starting
        #expect(starting.isStarting && model.displayed?.session.id == record.id)
        #expect(model.settleCommandTitle == "Settle Session" && model.canToggleSettled)
        await model.toggleSettled()
        #expect(try await settledAt(record.id, sessions) != nil)
        #expect(sessions.owners.contains { $0 === starting } && starting.isStarting)
        #expect(model.settleCommandTitle == "Unsettle Session" && model.canToggleSettled)
        await model.toggleSettled()
        #expect(try await settledAt(record.id, sessions) == nil)
        // Shown by itself, a starting session is cancelled, not settled.
        model.show(starting)
        #expect(model.settleCommandTitle == "Cancel Startup" && model.toolbarSettle?.title == "Cancel Startup")
        gate.release()
        await sessions.closeAll()
    }

    @Test func aFailingRuleLeavesTheRefreshWorking() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = try manager()
        let model = SessionWindowModel(sessions: sessions)
        let store = try await sessions.library.store()
        let project = ProjectRecord(name: "Project", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Agent", executable: "agent")
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        let old = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
        let (failing, quiet) = (
            SessionRecord(projectID: project.id, agentInstallID: agent.id, workingDirectory: "/a", createdAt: old),
            SessionRecord(projectID: project.id, agentInstallID: agent.id, workingDirectory: "/b", createdAt: old)
        )
        try await store.createSession(failing)
        try await store.createSession(quiet)
        let failingID = failing.id
        sessions.settledWrite = { settledAt, id in
            struct Refused: Error {}
            if id == failingID { throw Refused() }
            try await store.setSettled(settledAt, of: id)
        }
        await model.refresh()
        #expect(model.errorMessage == nil)
        #expect(Set(model.history.map(\.id)) == [failing.id, quiet.id])
        #expect(model.history.first { $0.id == quiet.id }?.settledAt != nil)
        #expect(model.sidebar.section(.active)?.rows.map(\.id) == [AnyHashable(failing.id)])
    }
}

@MainActor private final class Gate {
    private var continuation: CheckedContinuation<[String: String], Never>?

    func wait() async -> [String: String] { await withCheckedContinuation { continuation = $0 } }

    func release() {
        continuation?.resume(returning: ProcessInfo.processInfo.environment)
        continuation = nil
    }
}
