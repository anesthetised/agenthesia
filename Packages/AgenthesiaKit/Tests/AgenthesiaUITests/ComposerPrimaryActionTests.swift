import Testing

@testable import AgenthesiaUI

@MainActor struct ComposerPrimaryActionTests {
    private func action(
        active: Bool = false,
        draft: Bool = false,
        editing: Bool = false,
        idle: Bool = true
    ) -> ComposerPrimaryAction {
        ComposerPrimaryAction(turnActive: active, hasDraft: draft, editingQueued: editing, idleWithEmptyQueue: idle)
    }

    @Test func sendsWhenIdleAndQueuesBehindARunningTurnOrAQueue() {
        #expect(action(draft: true) == .send && action() == .send)
        #expect(action(active: true, draft: true, idle: false) == .queue)
        #expect(action(draft: true, idle: false) == .queue)
    }

    @Test func stopReplacesSendOnlyForAnEmptyDraftWhileATurnIsActive() {
        #expect(action(active: true, idle: false) == .stop)
        #expect(action(active: true, draft: true, idle: false) != .stop)
        #expect(action(idle: false) == .queue)
    }

    @Test func editingAQueuedMessageSaves() {
        for active in [false, true] {
            for draft in [false, true] { #expect(action(active: active, draft: draft, editing: true) == .save) }
        }
    }

    @Test func labelsAndSymbolsDescribeEachAction() {
        #expect([ComposerPrimaryAction.send, .queue, .save, .stop].map(\.title) == ["Send", "Queue", "Save", "Stop"])
        #expect(ComposerPrimaryAction.stop.symbol == "stop.fill")
        #expect([ComposerPrimaryAction.send, .queue, .save].allSatisfy { $0.symbol == "arrow.up" })
        #expect(ComposerPrimaryAction.queue.help.hasPrefix("Queue"))
    }
}
