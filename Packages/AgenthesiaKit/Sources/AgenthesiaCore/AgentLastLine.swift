extension TranscriptState {
    /// What the agent last said or is doing, for the session board (ADR-0046): the title of the latest tool call that
    /// still runs, or the first line of the latest assistant message, whichever came last, reduced to one line like a
    /// sidebar reason. Nil until the agent has said something.
    public var agentLastLine: String? {
        for item in items.reversed() {
            if let call = item.toolCall, [nil, .pending, .inProgress].contains(call.status),
                let title = SidebarReason.displayTitle(call.title)
            {
                return title
            }
            if let message = item.message, message.role == .assistant,
                let line = SidebarReason.displayTitle(message.text)
            {
                return line
            }
        }
        return nil
    }
}
