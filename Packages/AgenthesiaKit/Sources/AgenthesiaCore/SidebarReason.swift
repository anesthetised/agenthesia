public import ACP

/// The reason a sidebar row gives for its status symbol: what the session waits for, or how it finished
/// (ADR-0039's amendment). It follows `LiveSession.Activity`, so it never contradicts the symbol.
public enum SidebarReason {
    /// The longest tool title shown, ellipsis included.
    static let titleLimit = 120

    /// - Parameters:
    ///   - permissionTitles: The tool titles of the pending permission requests, oldest first.
    ///   - stopReason: How the last turn ended, for a finished session.
    ///   - promptFailed: The agent rejected the last prompt.
    ///   - queuePaused: The queue holds prompts and will not send them.
    /// - Returns: Nil when the symbol and the section say it all.
    public static func text(
        activity: LiveSession.Activity,
        signIn: Bool = false,
        permissionTitles: [String?] = [],
        starting: Bool = false,
        stopping: Bool = false,
        merging: Bool = false,
        stopReason: ACP.StopReason? = nil,
        promptFailed: Bool = false,
        queuePaused: Bool = false
    ) -> String? {
        switch activity {
        case .needsInput:
            if signIn { return "Sign in" }
            guard let oldest = permissionTitles.first else { return "Question" }
            guard let title = oldest.flatMap(displayTitle) else { return "Permission" }
            let more = permissionTitles.count - 1
            return more > 0 ? "Allow? \(title) +\(more)" : "Allow? \(title)"
        case .failed: return "Failed"
        case .working: return starting ? "Starting" : stopping ? "Stopping" : nil
        case .done:
            switch stopReason {
            case .refusal: return "Refused"
            case .maxTokens, .maxTurnRequests: return "Hit a limit"
            default: return "Finished"
            }
        case .idle: return merging ? "Merging" : promptFailed ? "Prompt failed" : queuePaused ? "Queue paused" : nil
        }
    }

    /// An agent-authored title reduced to its first line, whitespace collapsed, at most ``titleLimit`` characters.
    static func displayTitle(_ title: String) -> String? {
        let lines = title.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }
        guard let words = lines.first(where: { !$0.isEmpty }) else { return nil }
        let line = words.joined(separator: " ")
        return line.count > titleLimit ? line.prefix(titleLimit - 1) + "…" : line
    }
}
