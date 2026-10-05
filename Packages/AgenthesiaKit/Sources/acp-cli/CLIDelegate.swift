import ACP

/// Shows agent output on the console and asks the user for permissions.
struct CLIDelegate: ACP.AgentConnectionDelegate {
    let console: Console
    let input: LineReader

    func sessionUpdate(_ update: ACP.SessionUpdate, in sessionId: ACP.SessionID) async {
        await console.show(update)
    }

    func requestPermission(
        for toolCall: ACP.ToolCallUpdate,
        options: [ACP.PermissionOption],
        in sessionId: ACP.SessionID
    ) async -> ACP.PermissionOutcome {
        guard !options.isEmpty else { return .cancelled }
        let known = await console.title(of: toolCall.toolCallId)
        let title = toolCall.title ?? known ?? toolCall.toolCallId
        await console.prompt(PermissionPrompt.render(title: title, options: options))
        while true {
            guard let line = await input.next() else { return .cancelled }
            if let outcome = PermissionPrompt.parse(line, options: options) {
                return outcome
            }
            await console.prompt("Choose 1–\(options.count): ")
        }
    }
}
