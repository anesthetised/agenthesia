public import JSONRPC

extension ACP {
    public enum ToolKind: OpenEnum {
        case read, edit, delete, move, search, execute, think, fetch, switchMode, other
        case unknown(String)

        public static let knownCases: [ToolKind] = [
            .read, .edit, .delete, .move, .search, .execute, .think, .fetch, .switchMode, .other,
        ]

        public var rawValue: String {
            switch self {
            case .read: "read"
            case .edit: "edit"
            case .delete: "delete"
            case .move: "move"
            case .search: "search"
            case .execute: "execute"
            case .think: "think"
            case .fetch: "fetch"
            case .switchMode: "switch_mode"
            case .other: "other"
            case .unknown(let value): value
            }
        }
    }

    public enum ToolCallStatus: OpenEnum {
        case pending, inProgress, completed, failed
        case unknown(String)

        public static let knownCases: [ToolCallStatus] = [.pending, .inProgress, .completed, .failed]

        public var rawValue: String {
            switch self {
            case .pending: "pending"
            case .inProgress: "in_progress"
            case .completed: "completed"
            case .failed: "failed"
            case .unknown(let value): value
            }
        }
    }

    /// Regular content produced by a tool call.
    public struct ToolCallContentBlock: Codable, Hashable, Sendable {
        public var content: ContentBlock
        public var meta: Meta?

        public init(content: ContentBlock, meta: Meta? = nil) {
            self.content = content
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case content
            case meta = "_meta"
        }
    }

    /// A file modification shown as a diff.
    public struct Diff: Codable, Hashable, Sendable {
        public var path: String
        /// The original text; `nil` for a new file.
        public var oldText: String?
        public var newText: String
        public var meta: Meta?

        public init(path: String, oldText: String?, newText: String, meta: Meta? = nil) {
            self.path = path
            self.oldText = oldText
            self.newText = newText
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case path, oldText, newText
            case meta = "_meta"
        }
    }

    /// A reference to a terminal whose output is shown as part of a tool call.
    public struct TerminalReference: Codable, Hashable, Sendable {
        public var terminalId: TerminalID
        public var meta: Meta?

        public init(terminalId: TerminalID, meta: Meta? = nil) {
            self.terminalId = terminalId
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case terminalId
            case meta = "_meta"
        }
    }

    public enum ToolCallContent: Codable, Hashable, Sendable {
        case content(ToolCallContentBlock)
        case diff(Diff)
        case terminal(TerminalReference)
        case unknown(JSONValue)

        public init(from decoder: any Decoder) throws {
            switch try Tagged.tag(in: decoder, key: "type") {
            case "content": self = .content(try ToolCallContentBlock(from: decoder))
            case "diff": self = .diff(try Diff(from: decoder))
            case "terminal": self = .terminal(try TerminalReference(from: decoder))
            default: self = .unknown(try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .content(let content): try Tagged.encode(content, tag: "content", key: "type", to: encoder)
            case .diff(let diff): try Tagged.encode(diff, tag: "diff", key: "type", to: encoder)
            case .terminal(let terminal): try Tagged.encode(terminal, tag: "terminal", key: "type", to: encoder)
            case .unknown(let raw): try raw.encode(to: encoder)
            }
        }
    }

    public struct ToolCallLocation: Codable, Hashable, Sendable {
        public var path: String
        /// 1-based line number.
        public var line: Int?
        public var meta: Meta?

        public init(path: String, line: Int? = nil, meta: Meta? = nil) {
            self.path = path
            self.line = line
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case path, line
            case meta = "_meta"
        }
    }

    /// A new tool call reported by the agent.
    public struct ToolCall: Codable, Hashable, Sendable {
        public var toolCallId: ToolCallID
        public var title: String
        public var name: String?
        public var kind: ToolKind?
        public var status: ToolCallStatus?
        public var content: [ToolCallContent]?
        public var locations: [ToolCallLocation]?
        public var rawInput: JSONValue?
        public var rawOutput: JSONValue?
        public var meta: Meta?

        public init(
            toolCallId: ToolCallID,
            title: String,
            name: String? = nil,
            kind: ToolKind? = nil,
            status: ToolCallStatus? = nil,
            content: [ToolCallContent]? = nil,
            locations: [ToolCallLocation]? = nil,
            rawInput: JSONValue? = nil,
            rawOutput: JSONValue? = nil,
            meta: Meta? = nil
        ) {
            self.toolCallId = toolCallId
            self.title = title
            self.name = name
            self.kind = kind
            self.status = status
            self.content = content
            self.locations = locations
            self.rawInput = rawInput
            self.rawOutput = rawOutput
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case toolCallId, title, name, kind, status, content, locations, rawInput, rawOutput
            case meta = "_meta"
        }
    }

    /// Changes to an existing tool call. Only `toolCallId` is required; absent fields are unchanged.
    public struct ToolCallUpdate: Codable, Hashable, Sendable {
        public var toolCallId: ToolCallID
        public var title: String?
        public var name: String?
        public var kind: ToolKind?
        public var status: ToolCallStatus?
        public var content: [ToolCallContent]?
        public var locations: [ToolCallLocation]?
        public var rawInput: JSONValue?
        public var rawOutput: JSONValue?
        public var meta: Meta?

        public init(
            toolCallId: ToolCallID,
            title: String? = nil,
            name: String? = nil,
            kind: ToolKind? = nil,
            status: ToolCallStatus? = nil,
            content: [ToolCallContent]? = nil,
            locations: [ToolCallLocation]? = nil,
            rawInput: JSONValue? = nil,
            rawOutput: JSONValue? = nil,
            meta: Meta? = nil
        ) {
            self.toolCallId = toolCallId
            self.title = title
            self.name = name
            self.kind = kind
            self.status = status
            self.content = content
            self.locations = locations
            self.rawInput = rawInput
            self.rawOutput = rawOutput
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case toolCallId, title, name, kind, status, content, locations, rawInput, rawOutput
            case meta = "_meta"
        }
    }
}
