public import Foundation
public import JSONRPC

/// Model Context Protocol: the subset the built-in `agenthesia` server needs (initialize, ping, tools).
///
/// See docs/adr/0049-built-in-agenthesia-mcp-server.md.
public enum MCP {
    /// The protocol version answered in `initialize`.
    public static let protocolVersion = "2025-06-18"

    /// Typed MCP methods, for `Connection.request(_:_:)`, `Connection.notify(_:_:)` and `Router`.
    public enum Method {
        public enum Initialize: RPCRequest {
            public typealias Params = InitializeRequest
            public typealias Result = InitializeResult
            public static let method = "initialize"
        }

        public enum Initialized: RPCNotification {
            public typealias Params = JSONRPC.Empty
            public static let method = "notifications/initialized"
        }

        public enum Ping: RPCRequest {
            public typealias Params = JSONRPC.Empty
            public typealias Result = JSONRPC.Empty
            public static let method = "ping"
        }

        public enum ListTools: RPCRequest {
            public typealias Params = ListToolsRequest
            public typealias Result = ListToolsResult
            public static let method = "tools/list"
        }

        public enum CallTool: RPCRequest {
            public typealias Params = CallToolRequest
            public typealias Result = CallToolResult
            public static let method = "tools/call"
        }
    }

    /// The name and version of a client or server.
    public struct Implementation: Codable, Hashable, Sendable {
        public var name: String
        public var version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    /// Parameters of `initialize`. The client's capabilities are kept as sent; the server uses none of them.
    public struct InitializeRequest: Codable, Hashable, Sendable {
        public var protocolVersion: String
        public var capabilities: JSONValue
        public var clientInfo: Implementation

        public init(
            protocolVersion: String = MCP.protocolVersion,
            capabilities: JSONValue = [:],
            clientInfo: Implementation
        ) {
            self.protocolVersion = protocolVersion
            self.capabilities = capabilities
            self.clientInfo = clientInfo
        }
    }

    /// Result of `initialize`.
    public struct InitializeResult: Codable, Hashable, Sendable {
        public var protocolVersion: String
        public var capabilities: ServerCapabilities
        public var serverInfo: Implementation
        public var instructions: String?

        public init(
            protocolVersion: String = MCP.protocolVersion,
            capabilities: ServerCapabilities = ServerCapabilities(),
            serverInfo: Implementation,
            instructions: String? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.capabilities = capabilities
            self.serverInfo = serverInfo
            self.instructions = instructions
        }
    }

    /// What a server offers. An empty `tools` object announces tools without `listChanged` notifications.
    public struct ServerCapabilities: Codable, Hashable, Sendable {
        public var tools: JSONRPC.Empty?

        public init(tools: JSONRPC.Empty? = JSONRPC.Empty()) {
            self.tools = tools
        }
    }

    /// A tool as `tools/list` describes it.
    public struct Tool: Codable, Hashable, Sendable {
        public var name: String
        public var description: String
        /// A JSON Schema object for the tool's arguments.
        public var inputSchema: JSONValue

        public init(name: String, description: String, inputSchema: JSONValue) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
        }
    }

    /// Parameters of `tools/list`. The server lists everything in one page and ignores `cursor`.
    public struct ListToolsRequest: Codable, Hashable, Sendable {
        public var cursor: String?

        public init(cursor: String? = nil) {
            self.cursor = cursor
        }
    }

    /// Result of `tools/list`.
    public struct ListToolsResult: Codable, Hashable, Sendable {
        public var tools: [Tool]

        public init(tools: [Tool]) {
            self.tools = tools
        }
    }

    /// Parameters of `tools/call`.
    public struct CallToolRequest: Codable, Hashable, Sendable {
        public var name: String
        public var arguments: JSONValue?

        public init(name: String, arguments: JSONValue? = nil) {
            self.name = name
            self.arguments = arguments
        }
    }

    /// Result of `tools/call`. `isError` marks a failure the model should see, as opposed to a protocol error.
    public struct CallToolResult: Codable, Hashable, Sendable {
        public var content: [Content]
        public var isError: Bool?

        public init(content: [Content], isError: Bool? = nil) {
            self.content = content
            self.isError = isError
        }

        /// A failed call with one text block.
        public static func error(_ message: String) -> CallToolResult {
            CallToolResult(content: [.text(message)], isError: true)
        }
    }

    /// A content block of a tool result. Image data travels as base64.
    public enum Content: Codable, Hashable, Sendable {
        case text(String)
        case image(Data, mimeType: String)

        private enum CodingKeys: String, CodingKey {
            case type, text, data, mimeType
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "text":
                self = .text(try container.decode(String.self, forKey: .text))
            case "image":
                self = .image(
                    try container.decode(Data.self, forKey: .data),
                    mimeType: try container.decode(String.self, forKey: .mimeType)
                )
            case let type:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unsupported content type \(type)"
                )
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let data, let mimeType):
                try container.encode("image", forKey: .type)
                try container.encode(data, forKey: .data)
                try container.encode(mimeType, forKey: .mimeType)
            }
        }
    }
}
