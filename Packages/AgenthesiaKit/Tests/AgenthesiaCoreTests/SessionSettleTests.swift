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

extension SessionManagerTests {
    @Test func settleWritesBeforeTheOwnerLeavesAndRemovesItWhenTheWriteFails() async throws {
        let (directory, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = manager.start(directory: directory, agent: try mock())
        await owner.startup?.value
        let store = try await manager.library.store()
        manager.settledWrite = { [weak manager] settledAt, id in
            // Windows refresh when the owner leaves; by then `settledAt` must be written.
            let closedButListed = await MainActor.run {
                manager?.owners.contains { $0 === owner } == true && !owner.isLive
            }
            #expect(closedButListed)
            try await store.setSettled(settledAt, of: id)
        }
        try await manager.settle(owner)
        #expect(manager.owners.isEmpty)

        struct Refused: Error {}
        manager.settledWrite = { _, _ in throw Refused() }
        let failing = manager.start(directory: directory, agent: try mock())
        await failing.startup?.value
        await #expect(throws: Refused.self) { try await manager.settle(failing) }
        #expect(manager.owners.isEmpty && !failing.isLive)
    }

    @Test func theRuleSettlesTheOthersWhenOneWriteFails() async throws {
        let (directory, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await manager.library.store()
        let project = ProjectRecord(name: "P", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "A", executable: "a")
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        let old = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
        let ids = [UUID(), UUID(), UUID()]
        for id in ids {
            try await store.createSession(
                SessionRecord(
                    id: id,
                    projectID: project.id,
                    agentInstallID: agent.id,
                    workingDirectory: "/x",
                    createdAt: old
                )
            )
        }
        struct Refused: Error {}
        let failing = ids[1]
        manager.settledWrite = { settledAt, id in
            if id == failing { throw Refused() }
            try await store.setSettled(settledAt, of: id)
        }
        await #expect(throws: Refused.self) { try await manager.settleByRule() }
        var settled: [Bool] = []
        for id in ids { settled.append(try await store.session(id: id)?.settledAt != nil) }
        #expect(settled == [true, false, true])
    }

    @Test func continueIsRefusedWhileAnUnsettleRuns() async throws {
        let (directory, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = manager.start(directory: directory, agent: try mock(arguments: ["--reopen"]))
        await owner.startup?.value
        let record = try #require(owner.controller?.session)
        try await manager.settle(owner)
        manager.unsettlingIDs.insert(record.id)
        #expect(manager.resume(record) == nil && manager.owners.isEmpty)
        #expect(!manager.canUnsettle(record.id))
        manager.unsettlingIDs.remove(record.id)
        // An Unsettle of a session that is not settled writes nothing.
        try await manager.unsettle(record.id)
        try await manager.unsettle(record.id)
        let kinds = try await manager.library.store().events(in: record.id).map(\.event.kind)
        #expect(kinds.filter { $0 == SessionUnsettled.kind }.count == 1)
    }
}

extension WorktreeDiscardTests {
    /// Unsettle is a list decision: the outcome stays, and so does what it allows (ADR-0032's amendment).
    @Test func anUnsettledDiscardedSessionKeepsItsOutcome() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = fixture.manager
        let (_, session) = try await start(fixture)
        try await manager.discard(session)
        try await manager.settleByRule()
        let store = try await manager.library.store()
        #expect(try await store.session(id: session.id)?.settledAt != nil)

        try await manager.unsettle(session.id)
        let unsettledAt = try #require(try await store.lastEvents()[session.id])
        #expect(unsettledAt.event.kind == SessionUnsettled.kind)
        #expect(
            try await store.lastEvents(skipping: SessionUnsettled.kind)[session.id]?.sequence == unsettledAt.sequence
                - 1
        )
        #expect(try await manager.library.worktreeOutcomes() == [session.id: .discarded])
        let (outcomes, activity) = try await manager.library.lastEvents()
        #expect(outcomes == [session.id: .discarded] && activity[session.id] == unsettledAt.event.timestamp)
        #expect(try await manager.deleteSummary(session) == .discarded)
        await #expect(throws: SessionManager.DiscardError.alreadyRemoved) { try await manager.discard(session) }
        // Not settled again for its outcome; the seven days count from the Unsettle.
        try await manager.settleByRule()
        #expect(try await store.session(id: session.id)?.settledAt == nil)
        try await manager.settleByRule(now: .now.addingTimeInterval(8 * 24 * 60 * 60))
        #expect(try await store.session(id: session.id)?.settledAt != nil)
        // Continue is still refused, and the refused Continue leaves it settled.
        let record = try #require(try await store.session(id: session.id))
        let continued = try #require(manager.resume(record))
        await continued.startup?.value
        #expect(!continued.isLive && continued.errorMessage?.contains("cannot continue") == true)
        #expect(try await store.session(id: session.id)?.settledAt != nil)
        await manager.closeAll()
    }
}
