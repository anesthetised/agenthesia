public import ACP
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

    public struct Item: Identifiable, Equatable, Sendable {
        /// Sequence of the first event contributing this row; stable across replay.
        public let id: Int64
        public var message: Message?
        public var toolCall: ACP.ToolCall?
        public var notice: String?
        public var permission: ACP.PermissionOutcome?
    }

    public private(set) var items: [Item] = []
    public private(set) var sequence: Int64 = 0
    public private(set) var activeTurn: UUID?
    public private(set) var stopRequested = false
    public private(set) var lastStopReason: ACP.StopReason?
    public private(set) var plan: ACP.Plan?
    public private(set) var commands: [ACP.AvailableCommand] = []
    public private(set) var configOptions: [ACP.ConfigOption] = []
    public private(set) var currentModeID: ACP.SessionModeID?
    public private(set) var title: String?
    public private(set) var usage: ACP.UsageUpdate?
    public private(set) var unsupportedEvents = 0
    private var toolIndices: [ACP.ToolCallID: Int] = [:]

    public init() {}

    public enum ReplayError: Error, Equatable {
        case outOfOrder(expected: Int64, actual: Int64)
    }

    /// A pure, deterministic reduction. Unknown kinds and versions advance the cursor without data loss.
    public mutating func apply(_ event: StoredEvent) throws {
        guard event.sequence == sequence + 1 else {
            throw ReplayError.outOfOrder(expected: sequence + 1, actual: event.sequence)
        }
        if event.event.formatVersion != 1 {
            unsupportedEvents += 1
        } else if event.event.kind == SessionEvent.kind {
            let local = try JSONDecoder().decode(SessionEvent.self, from: event.event.payload)
            apply(local, sequence: event.sequence)
        } else if event.event.kind == SessionEvent.updateKind {
            let notification = try ACP.RecordedSessionUpdate(rawNotification: event.event.payload)
            apply(notification.update, sequence: event.sequence)
        } else {
            unsupportedEvents += 1
        }
        sequence = event.sequence
    }

    private mutating func apply(_ event: SessionEvent, sequence: Int64) {
        switch event {
        case .started(let options), .configOptions(let options):
            configOptions = options
        case .prompt(let id, let content):
            activeTurn = id
            stopRequested = false
            lastStopReason = nil
            items.append(
                Item(
                    id: sequence,
                    message: .init(role: .user, turnID: id, agentMessageID: nil, content: content, isLocalPrompt: true)
                )
            )
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
            items.append(Item(id: sequence, notice: message))
        case .permission(let tool, let outcome):
            merge(tool, sequence: sequence)
            if let index = toolIndices[tool.toolCallId] { items[index].permission = outcome }
        }
    }

    private mutating func apply(_ update: ACP.SessionUpdate, sequence: Int64) {
        switch update {
        case .userMessageChunk(let chunk): append(chunk, role: .user, sequence: sequence)
        case .agentMessageChunk(let chunk): append(chunk, role: .assistant, sequence: sequence)
        case .agentThoughtChunk(let chunk): append(chunk, role: .thought, sequence: sequence)
        case .toolCall(let call):
            if toolIndices[call.toolCallId] == nil {
                toolIndices[call.toolCallId] = items.count
                items.append(Item(id: sequence, toolCall: call))
            } else {
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
            }
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
        if let value = update.title { items[index].toolCall?.title = value }
        if let value = update.name { items[index].toolCall?.name = value }
        if let value = update.kind { items[index].toolCall?.kind = value }
        if let value = update.status { items[index].toolCall?.status = value }
        if let value = update.content { items[index].toolCall?.content = value }
        if let value = update.locations { items[index].toolCall?.locations = value }
        if let value = update.rawInput { items[index].toolCall?.rawInput = value }
        if let value = update.rawOutput { items[index].toolCall?.rawOutput = value }
        if let value = update.meta { items[index].toolCall?.meta = value }
    }
}
