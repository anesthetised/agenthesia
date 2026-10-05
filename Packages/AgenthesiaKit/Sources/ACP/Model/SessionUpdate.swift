public import JSONRPC

extension ACP {
    /// Why a prompt turn ended.
    public enum StopReason: OpenEnum {
        case endTurn, maxTokens, maxTurnRequests, refusal, cancelled
        case unknown(String)

        public static let knownCases: [StopReason] = [.endTurn, .maxTokens, .maxTurnRequests, .refusal, .cancelled]

        public var rawValue: String {
            switch self {
            case .endTurn: "end_turn"
            case .maxTokens: "max_tokens"
            case .maxTurnRequests: "max_turn_requests"
            case .refusal: "refusal"
            case .cancelled: "cancelled"
            case .unknown(let value): value
            }
        }
    }

    /// A streamed piece of a user message, an agent message or an agent thought.
    public struct ContentChunk: Codable, Hashable, Sendable {
        public var content: ContentBlock
        public var messageId: MessageID?
        public var meta: Meta?

        public init(content: ContentBlock, messageId: MessageID? = nil, meta: Meta? = nil) {
            self.content = content
            self.messageId = messageId
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case content, messageId
            case meta = "_meta"
        }
    }

    public struct AvailableCommandsUpdate: Codable, Hashable, Sendable {
        public var availableCommands: [AvailableCommand]
        public var meta: Meta?

        public init(availableCommands: [AvailableCommand], meta: Meta? = nil) {
            self.availableCommands = availableCommands
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case availableCommands
            case meta = "_meta"
        }
    }

    /// The current session mode changed (ACP v1 session modes).
    public struct CurrentModeUpdate: Codable, Hashable, Sendable {
        public var currentModeId: SessionModeID
        public var meta: Meta?

        public init(currentModeId: SessionModeID, meta: Meta? = nil) {
            self.currentModeId = currentModeId
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case currentModeId
            case meta = "_meta"
        }
    }

    public struct ConfigOptionsUpdate: Codable, Hashable, Sendable {
        public var configOptions: [ConfigOption]
        public var meta: Meta?

        public init(configOptions: [ConfigOption], meta: Meta? = nil) {
            self.configOptions = configOptions
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case configOptions
            case meta = "_meta"
        }
    }

    /// Session metadata changed. Absent fields are unchanged.
    public struct SessionInfoUpdate: Codable, Hashable, Sendable {
        public var title: String?
        /// ISO 8601 timestamp.
        public var updatedAt: String?
        public var meta: Meta?

        public init(title: String? = nil, updatedAt: String? = nil, meta: Meta? = nil) {
            self.title = title
            self.updatedAt = updatedAt
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case title, updatedAt
            case meta = "_meta"
        }
    }

    public struct Cost: Codable, Hashable, Sendable {
        public var amount: Double
        public var currency: String
        public var meta: Meta?

        public init(amount: Double, currency: String, meta: Meta? = nil) {
            self.amount = amount
            self.currency = currency
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case amount, currency
            case meta = "_meta"
        }
    }

    /// Context window usage and cost of the session.
    public struct UsageUpdate: Codable, Hashable, Sendable {
        /// Tokens currently in context.
        public var used: Int
        /// Size of the context window in tokens.
        public var size: Int
        public var cost: Cost?
        public var meta: Meta?

        public init(used: Int, size: Int, cost: Cost? = nil, meta: Meta? = nil) {
            self.used = used
            self.size = size
            self.cost = cost
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case used, size, cost
            case meta = "_meta"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            used = try container.decode(Int.self, forKey: .used)
            size = try container.decode(Int.self, forKey: .size)
            cost = try? container.decodeIfPresent(Cost.self, forKey: .cost)
            meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
        }
    }

    /// A real-time update about a session, sent by the agent.
    public enum SessionUpdate: Codable, Hashable, Sendable {
        case userMessageChunk(ContentChunk)
        case agentMessageChunk(ContentChunk)
        case agentThoughtChunk(ContentChunk)
        case toolCall(ToolCall)
        case toolCallUpdate(ToolCallUpdate)
        case plan(Plan)
        case availableCommands(AvailableCommandsUpdate)
        case currentMode(CurrentModeUpdate)
        case configOptions(ConfigOptionsUpdate)
        case sessionInfo(SessionInfoUpdate)
        case usage(UsageUpdate)
        case unknown(JSONValue)

        private static let key = "sessionUpdate"

        public init(from decoder: any Decoder) throws {
            switch try Tagged.tag(in: decoder, key: Self.key) {
            case "user_message_chunk": self = .userMessageChunk(try ContentChunk(from: decoder))
            case "agent_message_chunk": self = .agentMessageChunk(try ContentChunk(from: decoder))
            case "agent_thought_chunk": self = .agentThoughtChunk(try ContentChunk(from: decoder))
            case "tool_call": self = .toolCall(try ToolCall(from: decoder))
            case "tool_call_update": self = .toolCallUpdate(try ToolCallUpdate(from: decoder))
            case "plan": self = .plan(try Plan(from: decoder))
            case "available_commands_update": self = .availableCommands(try AvailableCommandsUpdate(from: decoder))
            case "current_mode_update": self = .currentMode(try CurrentModeUpdate(from: decoder))
            case "config_option_update": self = .configOptions(try ConfigOptionsUpdate(from: decoder))
            case "session_info_update": self = .sessionInfo(try SessionInfoUpdate(from: decoder))
            case "usage_update": self = .usage(try UsageUpdate(from: decoder))
            default: self = .unknown(try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .userMessageChunk(let chunk): try Self.encode(chunk, "user_message_chunk", encoder)
            case .agentMessageChunk(let chunk): try Self.encode(chunk, "agent_message_chunk", encoder)
            case .agentThoughtChunk(let chunk): try Self.encode(chunk, "agent_thought_chunk", encoder)
            case .toolCall(let call): try Self.encode(call, "tool_call", encoder)
            case .toolCallUpdate(let update): try Self.encode(update, "tool_call_update", encoder)
            case .plan(let plan): try Self.encode(plan, "plan", encoder)
            case .availableCommands(let update): try Self.encode(update, "available_commands_update", encoder)
            case .currentMode(let update): try Self.encode(update, "current_mode_update", encoder)
            case .configOptions(let update): try Self.encode(update, "config_option_update", encoder)
            case .sessionInfo(let update): try Self.encode(update, "session_info_update", encoder)
            case .usage(let update): try Self.encode(update, "usage_update", encoder)
            case .unknown(let raw): try raw.encode(to: encoder)
            }
        }

        private static func encode(_ payload: some Encodable, _ tag: String, _ encoder: any Encoder) throws {
            try Tagged.encode(payload, tag: tag, key: key, to: encoder)
        }
    }
}
