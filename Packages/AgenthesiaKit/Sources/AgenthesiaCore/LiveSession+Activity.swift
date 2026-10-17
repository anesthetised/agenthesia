extension LiveSession {
    /// A live session's state in priority order (ADR-0026).
    public enum Activity: String, Sendable {
        case needsInput = "Needs input"
        case failed = "Failed"
        case working = "Working"
        case done = "Done"
        case idle = "Idle"

        static func derive(
            starting: Bool,
            failed: Bool,
            status: SessionController.Status?,
            needsInput: Bool,
            unseen: Bool
        ) -> Activity {
            if needsInput { return .needsInput }
            if failed || status == .failed { return .failed }
            if starting || [.starting, .running, .stopping].contains(status) { return .working }
            return unseen ? .done : .idle
        }
    }
}
