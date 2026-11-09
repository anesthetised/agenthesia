import ACP
import Foundation
import JSONRPC
import Testing

@testable import AgenthesiaCore
@testable import Persistence

@Suite struct PlanProgressTests {
    private func plan(_ statuses: [ACP.PlanEntryStatus]) -> ACP.Plan {
        .init(
            entries: statuses.enumerated().map {
                .init(content: "Step \($0.offset + 1)", priority: .medium, status: $0.element)
            }
        )
    }

    @Test func noPlanOrAnEmptyOneHasNoProgress() {
        #expect(PlanProgress(nil) == nil)
        #expect(PlanProgress(plan([])) == nil)
    }

    @Test func withoutAnEntryInProgressTheCountIsDone() throws {
        let progress = try #require(PlanProgress(plan([.completed, .pending, .pending])))
        #expect(progress.completed == 1 && progress.total == 3 && progress.current == nil)
        #expect(progress.summary == "1 of 3 done")
    }

    @Test func theFirstEntryInProgressIsTheCurrentStep() throws {
        let progress = try #require(PlanProgress(plan([.completed, .inProgress, .inProgress, .pending])))
        #expect(progress.current == "Step 2")
        #expect(progress.summary == "1 of 4 · Step 2")
    }

    @Test func allCompleted() throws {
        #expect(try #require(PlanProgress(plan([.completed, .completed]))).summary == "2 of 2 done")
    }

    @Test func unknownStatusesCountAsNotDoneAndNotCurrent() throws {
        let progress = try #require(PlanProgress(plan([.unknown("blocked"), .completed])))
        #expect(progress.completed == 1 && progress.total == 2 && progress.current == nil)
    }

    @Test func theStepIsOneLineLikeAnyReason() throws {
        let entry = ACP.PlanEntry(content: "\n  Write   the\ntests ", priority: .high, status: .inProgress)
        #expect(try #require(PlanProgress(.init(entries: [entry]))).current == "Write the")
        let long = ACP.PlanEntry(content: String(repeating: "a", count: 200), priority: .high, status: .inProgress)
        #expect(try #require(PlanProgress(.init(entries: [long]))).current?.count == SidebarReason.titleLimit)
    }

    @Test func aNewTurnClearsTheLastTurnsPlan() throws {
        let id = UUID()
        var state = TranscriptState()
        var sequence: Int64 = 0
        func apply(_ event: NewEvent) throws {
            sequence += 1
            try state.apply(StoredEvent(sessionID: id, sequence: sequence, event: event))
        }
        func update(_ plan: ACP.Plan) throws -> NewEvent {
            let payload = try JSONEncoder().encode(
                Message.notification(
                    method: "session/update",
                    params: try JSONValue(encoding: ACP.V1.SessionNotification(sessionId: "s", update: .plan(plan)))
                )
            )
            return NewEvent(kind: SessionEvent.updateKind, payload: payload)
        }
        try apply(SessionEvent.prompt(id: UUID(), content: []).storedEvent())
        try apply(update(plan([.inProgress])))
        #expect(state.plan == plan([.inProgress]))
        try apply(SessionEvent.finished(id: try #require(state.activeTurn), reason: .endTurn).storedEvent())
        // The plan outlives its turn and goes when the next one starts.
        #expect(state.plan != nil)
        try apply(
            SessionEvent.promptMessage(
                prompt: .init(content: [.init(text: "next")]),
                turnID: UUID(),
                startsTurn: true,
                sentTogether: false
            ).storedEvent()
        )
        #expect(state.plan == nil)
    }
}
