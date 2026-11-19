import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore

/// Settling by hand and by rule (ADR-0050).
extension SessionManagerTests {
    private func settledAt(_ id: UUID, in manager: SessionManager) async throws -> Date? {
        try await manager.library.store().session(id: id)?.settledAt
    }

    @Test func settleEndsALiveSessionAndUnsettleBringsItBackWithAnEvent() async throws {
        let (directory, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = manager.start(directory: directory, agent: try mock(arguments: ["--reopen"]))
        await owner.startup?.value
        let id = try #require(owner.sessionID)
        try await manager.settle(owner)
        #expect(manager.owners.isEmpty && !owner.isLive)
        #expect(try await settledAt(id, in: manager) != nil)

        let store = try await manager.library.store()
        let before = try await store.lastEvents()[id]?.sequence ?? 0
        try await manager.unsettle(id)
        #expect(try await settledAt(id, in: manager) == nil)
        let events = try await store.events(in: id, after: before)
        #expect(events.map(\.event.kind) == [SessionUnsettled.kind])
        #expect(manager.owners.isEmpty)

        // Settling a saved session writes the time; Continue clears it, and Unsettle is refused while it starts.
        try await manager.settle(id)
        let record = try #require(try await store.session(id: id))
        #expect(record.settledAt != nil)
        let continued = try #require(manager.resume(record))
        #expect(!manager.canUnsettle(id))
        try await manager.unsettle(id)
        await continued.startup?.value
        #expect(continued.controller?.status == .idle)
        #expect(try await settledAt(id, in: manager) == nil)
        #expect(
            try await store.events(in: id, after: before).filter { $0.event.kind == SessionUnsettled.kind }.count == 1
        )
        await manager.closeAll()
    }

    @Test func theRuleSettlesQuietSavedSessionsAndNeverALiveOne() async throws {
        let (directory, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = manager.start(directory: directory, agent: try mock())
        await owner.startup?.value
        let live = try #require(owner.controller?.session)
        let store = try await manager.library.store()
        let now = Date.now
        let day: TimeInterval = 24 * 60 * 60
        func saved(age: Double) async throws -> UUID {
            let record = SessionRecord(
                projectID: live.projectID,
                agentInstallID: live.agentInstallID,
                workingDirectory: directory.path,
                createdAt: now.addingTimeInterval(-age * day)
            )
            try await store.createSession(record)
            return record.id
        }
        let (recent, quiet, merged) = try await (saved(age: 6), saved(age: 8), saved(age: 1))
        _ = try await store.append(
            [SessionEvent.worktreeRemoved(.merged(commit: "abc", into: "main")).storedEvent()],
            to: merged
        )
        try await manager.settleByRule(now: now)
        #expect(try await settledAt(recent, in: manager) == nil)
        #expect(try await settledAt(quiet, in: manager) == now)
        #expect(try await settledAt(merged, in: manager) == now)
        #expect(try await settledAt(live.id, in: manager) == nil)

        // An Unsettle counts as activity: the seven days start again from it.
        try await manager.unsettle(quiet)
        try await manager.settleByRule(now: now.addingTimeInterval(6 * day))
        #expect(try await settledAt(quiet, in: manager) == nil)
        try await manager.settleByRule(now: now.addingTimeInterval(8 * day))
        #expect(try await settledAt(quiet, in: manager) != nil)
        #expect(try await settledAt(live.id, in: manager) == nil)
        await manager.closeAll()
    }
}
