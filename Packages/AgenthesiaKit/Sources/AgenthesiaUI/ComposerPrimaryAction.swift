/// What the composer's round button does (ADR-0039): Send, Queue and Save share the arrow, and Queue and Save add
/// their name to it; Stop replaces it while a turn runs and there is nothing to send. While a form waits it reads
/// Next or Answer, so Return never queues behind the turn that waits for the answer (#326).
enum ComposerPrimaryAction: Equatable {
    case send, queue, save, stop, next, answer

    /// - Parameters:
    ///   - turnActive: a turn runs or stops, or the agent waits for the user's input.
    ///   - editingQueued: the draft edits a queued message.
    ///   - idleWithEmptyQueue: a new prompt would be sent at once instead of queued behind others.
    ///   - answering: a form is docked; true on its last step.
    init(turnActive: Bool, hasDraft: Bool, editingQueued: Bool, idleWithEmptyQueue: Bool, answering: Bool? = nil) {
        if let lastStep = answering {
            self = lastStep ? .answer : .next
        } else if editingQueued {
            self = .save
        } else if turnActive && !hasDraft {
            self = .stop
        } else {
            self = idleWithEmptyQueue ? .send : .queue
        }
    }

    var title: String {
        switch self {
        case .send: "Send"
        case .queue: "Queue"
        case .save: "Save"
        case .stop: "Stop"
        case .next: "Next"
        case .answer: "Answer"
        }
    }

    /// Queue, Save, Next and Answer look like Send, so they say what they do next to the arrow.
    var showsTitle: Bool { self != .send && self != .stop }

    /// The Send options item that sends at once; steering interrupts a running turn (ADR-0028).
    static func sendNowTitle(hasDraft: Bool, turnActive: Bool) -> String {
        (hasDraft ? "Send Draft Now" : "Send Queue Now") + (turnActive ? " (Interrupts Turn)" : "")
    }

    var symbol: String { self == .stop ? "stop.fill" : "arrow.up" }

    var help: String {
        switch self {
        case .send: "Send the message (Return)"
        case .queue: "Queue the message until the agent is ready (Return)"
        case .save: "Save the queued message (Return)"
        case .stop: "Stop the current turn (⌘.)"
        case .next: "Answer this question and go to the next (Return)"
        case .answer: "Send the answers to the agent (Return)"
        }
    }
}
