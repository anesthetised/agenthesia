public import ACP
public import AgentRuntime
public import Foundation
public import Persistence

/// Plain domain values; rendering and display cadence belong to the UI.
public struct TranscriptState: Equatable, Sendable {
    public enum Role: Equatable, Sendable { case user, assistant, thought }

    public struct Message: Equatable, Sendable {
        public let role: Role
        public let turnID: UUID?
        public let agentMessageID: ACP.MessageID?
        public var content: [ACP.ContentBlock]
        public var isLocalPrompt = false
        public var localPromptID: UUID?
        public var sentTogether = false
        public var notSent = false
        /// Who sent a user-role message: the user, or another session (ADR-0049).
        public var origin = QueuedPrompt.Origin.user
        /// A thought's first chunk, and the last event of its turn before another item followed it (ADR-0039's
        /// amendment). Nil for other roles.
        public var thoughtStart: Date?
        public var thoughtEnd: Date?

        /// How long a thought took; 0 without its times.
        public var thoughtDuration: TimeInterval {
            guard let thoughtStart, let thoughtEnd else { return 0 }
            return max(0, thoughtEnd.timeIntervalSince(thoughtStart))
        }

        public var text: String {
            content.compactMap { if case .text(let block) = $0 { block.text } else { nil } }.joined()
        }

        mutating func append(_ block: ACP.ContentBlock) {
            if case .text(let incoming) = block, case .text(let previous) = content.last,
                incoming.annotations == previous.annotations, incoming.meta == previous.meta
            {
                // Remove the old value before mutation so growing text can reuse its buffer.
                if case .text(var tail) = content.removeLast() {
                    tail.text += incoming.text
                    content.append(.text(tail))
                }
            } else {
                content.append(block)
            }
        }
    }

    /// One permission request. Requests that refer to the same tool call remain separate rows.
    public struct Permission: Equatable, Sendable {
        /// `nil` for a decision recorded before requests had their own events.
        public let requestID: UUID?
        /// The tool call as known when the agent asked.
        public let toolCall: ACP.ToolCall
        /// The agent's offered options; empty for decisions recorded before requests had their own events.
        public let options: [ACP.PermissionOption]
        /// The response returned to the agent; `nil` while none is recorded.
        public var outcome: ACP.PermissionOutcome?

        public var selectedOption: ACP.PermissionOption? {
            guard case .selected(let id) = outcome else { return nil }
            return options.first { $0.optionId == id }
        }
    }

    public struct Input: Equatable, Sendable {
        public let requestID: UUID
        public let request: ACP.ElicitationRequest
        public var response: ACP.ElicitationResponse?
    }

    /// Command output an agent reports in a tool call's `_meta` (ADR-0016): `terminal_output_delta` and
    /// `terminal_output` carry `data` to append, `terminal_exit` the end of the command.
    public struct CommandOutput: Equatable, Sendable {
        public struct Exit: Equatable, Sendable {
            public var exitCode: Int?
            public var signal: String?
        }

        /// The most recent bytes; older ones are dropped beyond this limit.
        public static let byteLimit = 1 << 20
        static let chunkKeys = ["terminal_output_delta", "terminal_output"]
        /// Keys whose content lives here instead of in the tool call's `meta`.
        static let keys = chunkKeys + ["terminal_exit"]

        public var output = TerminalOutput()
        public var exit: Exit?

        static func carries(_ meta: ACP.Meta) -> Bool {
            keys.contains { meta[$0] != nil }
        }

        mutating func apply(_ meta: ACP.Meta) {
            for key in Self.chunkKeys {
                guard case .object(let chunk)? = meta[key], case .string(let data)? = chunk["data"] else { continue }
                output.bytes.append(Data(data.utf8))
            }
            if output.bytes.count > Self.byteLimit {
                output.bytes.removeFirst(output.bytes.count - Self.byteLimit)
                output.truncated = true
            }
            if case .object(let end)? = meta["terminal_exit"] {
                var exit = Exit()
                if case .int(let code)? = end["exit_code"] { exit.exitCode = Int(code) }
                if case .string(let signal)? = end["signal"] { exit.signal = signal }
                self.exit = exit
            }
        }
    }

    public struct Item: Identifiable, Equatable, Sendable {
        /// Sequence of the first event contributing this row; stable across replay.
        public let id: Int64
        public var message: Message?
        public var toolCall: ACP.ToolCall?
        public var notice: String?
        /// `notice` is the stored description of a failed prompt, not a session notice.
        public var isFailure = false
        /// When a saved session was continued; shown as a divider.
        public var reopenedAt: Date?
        public var permission: Permission?
        public var input: Input?
        /// Output of the row's tool call, kept out of the call's `meta`.
        public var commandOutput: CommandOutput?
    }

    /// What a reader of the transcript's end has seen: the last item and how much text it holds. A different value
    /// means the end changed, by a new last item or by more text in it (ADR-0026's amendment).
    public struct End: Equatable, Sendable {
        public let item: Int64
        public let size: Int
    }

    /// `nil` while the transcript is empty. Reading it costs a comparison's worth, so tables may ask on every update.
    public var end: End? {
        guard let last = items.last else { return nil }
        var size = last.commandOutput?.output.bytes.count ?? 0
        if let content = last.message?.content {
            size += content.count
            if case .text(let block)? = content.last { size += block.text.utf8.count }
        }
        return End(item: last.id, size: size)
    }

    public private(set) var items: [Item] = []
    public private(set) var sequence: Int64 = 0
    public private(set) var queuedPrompts: [QueuedPrompt] = []
    public private(set) var queuePaused = false
    public private(set) var activeTurn: UUID?
    /// Who started the latest turn; the sidebar names it while the turn runs.
    public private(set) var turnOrigin = QueuedPrompt.Origin.user
    public private(set) var stopRequested = false
    public private(set) var lastStopReason: ACP.StopReason?
    /// The agent rejected the last turn's prompt; a new turn or a continued session clears it.
    public private(set) var lastTurnFailed = false
    /// The current turn's plan; a new turn clears it until the agent sends one (ADR-0039's amendment).
    public private(set) var plan: ACP.Plan?
    public private(set) var commands: [ACP.AvailableCommand] = []
    public private(set) var configOptions: [ACP.ConfigOption] = []
    public private(set) var currentModeID: ACP.SessionModeID?
    public private(set) var title: String?
    public private(set) var usage: ACP.UsageUpdate?
    public private(set) var unsupportedEvents = 0
    /// Set once the session's worktree was merged or discarded; such a session cannot continue.
    public private(set) var worktreeOutcome: WorktreeOutcome?
    /// The pull request opened from the session's branch (ADR-0045); the session stays live.
    public private(set) var pullRequest: PullRequest?
    private var toolIndices: [ACP.ToolCallID: Int] = [:]
    private var inputIndices: [UUID: Int] = [:]
    private var permissionIndices: [UUID: Int] = [:]

    public init() {}

    /// The default merge commit message: the agent's session title, or else the first line of the first prompt.
    public var mergeMessage: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        let prompt = items.lazy.compactMap(\.message).first { $0.role == .user }?.text ?? ""
        return prompt.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    /// Requests without a recorded response, oldest first.
    public var unansweredPermissions: [UUID] {
        permissionIndices.sorted { $0.value < $1.value }.compactMap {
            items[$0.value].permission?.outcome == nil ? $0.key : nil
        }
    }

    public var unansweredInputs: [UUID] {
        inputIndices.sorted { $0.value < $1.value }.compactMap {
            items[$0.value].input?.response == nil ? $0.key : nil
        }
    }

    public enum ReplayError: Error, Equatable {
        case outOfOrder(expected: Int64, actual: Int64)
    }

    /// A pure, deterministic reduction. Unknown kinds and versions advance the cursor without data loss.
    public mutating func apply(_ event: StoredEvent) throws {
        guard event.sequence == sequence + 1 else {
            throw ReplayError.outOfOrder(expected: sequence + 1, actual: event.sequence)
        }
        // A thought lasts from its first chunk until another item follows it or its turn ends.
        let thinking = activeTurn != nil && items.last?.message?.role == .thought ? items.count - 1 : nil
        let count = items.count
        if event.event.formatVersion != 1 {
            unsupportedEvents += 1
        } else if event.event.kind == SessionEvent.kind {
            let local = try JSONDecoder().decode(SessionEvent.self, from: event.event.payload)
            apply(local, sequence: event.sequence, timestamp: event.event.timestamp)
        } else if event.event.kind == PullRequest.kind {
            let opened = try JSONDecoder().decode(PullRequest.self, from: event.event.payload)
            pullRequest = opened
            items.append(Item(id: event.sequence, notice: opened.notice))
        } else if event.event.kind == SessionEvent.updateKind {
            let notification = try ACP.RecordedSessionUpdate(rawNotification: event.event.payload)
            apply(notification.update, sequence: event.sequence)
        } else {
            unsupportedEvents += 1
        }
        let time = event.event.timestamp
        if let thinking { items[thinking].message?.thoughtEnd = time }
        for index in count..<items.count where items[index].message?.role == .thought {
            items[index].message?.thoughtStart = time
            items[index].message?.thoughtEnd = time
        }
        sequence = event.sequence
    }

    private mutating func apply(_ event: SessionEvent, sequence: Int64, timestamp: Date) {
        switch event {
        case .started(let options), .configOptions(let options):
            configOptions = options
        case .reopened(let options, _):
            configOptions = options
            lastTurnFailed = false
            items.append(Item(id: sequence, reopenedAt: timestamp))
        case .prompt(let id, let content):
            activeTurn = id
            turnOrigin = .user
            plan = nil
            stopRequested = false
            lastStopReason = nil
            lastTurnFailed = false
            items.append(
                Item(
                    id: sequence,
                    message: .init(role: .user, turnID: id, agentMessageID: nil, content: content, isLocalPrompt: true)
                )
            )
        case .queueChanged(let prompts): queuedPrompts = prompts
        case .queuePaused(let paused): queuePaused = paused
        case .injectionPrepared(let prompts):
            let existing = Set(queuedPrompts.map(\.id))
            queuedPrompts += prompts.filter { !existing.contains($0.id) }
        case .promptsNotSent(let turnID, let prompts):
            let ids = Set(prompts.map(\.id))
            queuedPrompts = prompts + queuedPrompts.filter { !ids.contains($0.id) }
            for index in items.indices where items[index].message?.turnID == turnID {
                if let id = items[index].message?.localPromptID, ids.contains(id) {
                    items[index].message?.notSent = true
                }
            }
        case .promptMessage(let prompt, let turnID, let startsTurn, let sentTogether):
            if startsTurn {
                activeTurn = turnID
                turnOrigin = prompt.origin
                plan = nil
                stopRequested = false
                lastStopReason = nil
                lastTurnFailed = false
            }
            items.append(
                Item(
                    id: sequence,
                    message: .init(
                        role: .user,
                        turnID: turnID,
                        agentMessageID: nil,
                        content: prompt.content,
                        isLocalPrompt: true,
                        localPromptID: prompt.id,
                        sentTogether: sentTogether,
                        origin: prompt.origin
                    )
                )
            )
        case .interrupted:
            items.append(Item(id: sequence, notice: "Interrupted"))
        case .stopRequested(let id):
            if id == activeTurn { stopRequested = true }
        case .finished(let id, let reason):
            guard id == activeTurn else { return }
            activeTurn = nil
            stopRequested = false
            lastStopReason = reason
        case .failed(let id, let message):
            guard id == activeTurn else { return }
            activeTurn = nil
            stopRequested = false
            lastTurnFailed = true
            items.append(Item(id: sequence, notice: message, isFailure: true))
        case .inputRequested(let id, let request):
            inputIndices[id] = items.count
            items.append(Item(id: sequence, input: .init(requestID: id, request: request)))
        case .inputResolved(let id, let response):
            if let index = inputIndices[id] { items[index].input?.response = response }
        case .permission(let tool, let outcome):
            appendPermission(nil, tool: tool, options: [], outcome: outcome, sequence: sequence)
        case .permissionRequested(let id, let tool, let options):
            permissionIndices[id] = items.count
            appendPermission(id, tool: tool, options: options, outcome: nil, sequence: sequence)
        case .permissionResolved(let id, let outcome):
            if let index = permissionIndices[id] { items[index].permission?.outcome = outcome }
        case .worktreeRemoved(let outcome):
            worktreeOutcome = outcome
            items.append(Item(id: sequence, notice: outcome.notice))
        }
    }

    private mutating func appendPermission(
        _ id: UUID?,
        tool: ACP.ToolCallUpdate,
        options: [ACP.PermissionOption],
        outcome: ACP.PermissionOutcome?,
        sequence: Int64
    ) {
        // A request for an unknown call keeps its context in its own row; a tool row would share its identity.
        let index = toolIndices[tool.toolCallId]
        var call = index.flatMap { items[$0].toolCall } ?? .init(toolCallId: tool.toolCallId, title: "")
        call.apply(tool)
        if let index { items[index].toolCall = call }
        items.append(
            Item(
                id: sequence,
                permission: .init(requestID: id, toolCall: call, options: options, outcome: outcome)
            )
        )
    }

    private mutating func apply(_ update: ACP.SessionUpdate, sequence: Int64) {
        switch update {
        case .userMessageChunk(let chunk): append(chunk, role: .user, sequence: sequence)
        case .agentMessageChunk(let chunk): append(chunk, role: .assistant, sequence: sequence)
        case .agentThoughtChunk(let chunk): append(chunk, role: .thought, sequence: sequence)
        case .toolCall(let call):
            // Updates may precede the call; fields it omits keep their reported values.
            merge(
                .init(
                    toolCallId: call.toolCallId,
                    title: call.title,
                    name: call.name,
                    kind: call.kind,
                    status: call.status,
                    content: call.content,
                    locations: call.locations,
                    rawInput: call.rawInput,
                    rawOutput: call.rawOutput,
                    meta: call.meta
                ),
                sequence: sequence
            )
        case .toolCallUpdate(let update): merge(update, sequence: sequence)
        case .plan(let value): plan = value
        case .availableCommands(let value): commands = value.availableCommands
        case .configOptions(let value): configOptions = value.configOptions
        case .currentMode(let value): currentModeID = value.currentModeId
        case .sessionInfo(let value): if let title = value.title { self.title = title }
        case .usage(let value): usage = value
        case .unknown: unsupportedEvents += 1
        }
    }

    private mutating func append(_ chunk: ACP.ContentChunk, role: Role, sequence: Int64) {
        // Without a message id only contiguous chunks of the same role form a message.
        let index: Int?
        if let id = chunk.messageId {
            index = items.lastIndex {
                $0.message?.agentMessageID == id && $0.message?.role == role && $0.message?.turnID == activeTurn
            }
        } else if let last = items.last?.message, last.role == role,
            last.agentMessageID == nil, last.turnID == activeTurn,
            // A locally recorded prompt is complete, not the beginning of an agent's user-message stream.
            !last.isLocalPrompt
        {
            index = items.count - 1
        } else {
            index = nil
        }
        if let index {
            items[index].message?.append(chunk.content)
        } else {
            items.append(
                Item(
                    id: sequence,
                    message: .init(
                        role: role,
                        turnID: activeTurn,
                        agentMessageID: chunk.messageId,
                        content: [chunk.content]
                    )
                )
            )
        }
    }

    private mutating func merge(_ update: ACP.ToolCallUpdate, sequence: Int64) {
        if toolIndices[update.toolCallId] == nil {
            toolIndices[update.toolCallId] = items.count
            items.append(
                Item(
                    id: sequence,
                    // An empty title means none was reported yet.
                    toolCall: .init(toolCallId: update.toolCallId, title: update.title ?? "")
                )
            )
        }
        guard let index = toolIndices[update.toolCallId] else { return }
        items[index].toolCall?.apply(update)
        if let meta = update.meta, CommandOutput.carries(meta) {
            if items[index].commandOutput == nil { items[index].commandOutput = .init() }
            items[index].commandOutput?.apply(meta)
        }
    }
}

extension ACP.ToolCall {
    fileprivate mutating func apply(_ update: ACP.ToolCallUpdate) {
        if let value = update.title { title = value }
        if let value = update.name { name = value }
        if let value = update.kind { kind = value }
        if let value = update.status { status = value }
        if let value = update.content { content = value }
        if let value = update.locations { locations = value }
        if let value = update.rawInput { rawInput = value }
        if let value = update.rawOutput { rawOutput = value }
        if let value = update.meta {
            let kept = value.filter { !TranscriptState.CommandOutput.keys.contains($0.key) }
            // An update that carried only output leaves the reported meta alone.
            if !kept.isEmpty || value.isEmpty { meta = kept }
        }
    }
}
