/// What the composer's round button does (ADR-0039): Send, Queue and Save share the arrow; Stop replaces it while
/// a turn runs and there is nothing to send.
enum ComposerPrimaryAction: Equatable {
    case send, queue, save, stop

    /// - Parameters:
    ///   - turnActive: a turn runs or stops, or the agent waits for the user's input.
    ///   - editingQueued: the draft edits a queued message.
    ///   - idleWithEmptyQueue: a new prompt would be sent at once instead of queued behind others.
    init(turnActive: Bool, hasDraft: Bool, editingQueued: Bool, idleWithEmptyQueue: Bool) {
        if editingQueued {
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
        }
    }

    var symbol: String { self == .stop ? "stop.fill" : "arrow.up" }

    var help: String {
        switch self {
        case .send: "Send the message (Return)"
        case .queue: "Queue the message until the agent is ready (Return)"
        case .save: "Save the queued message (Return)"
        case .stop: "Stop the current turn (⌘.)"
        }
    }
}
