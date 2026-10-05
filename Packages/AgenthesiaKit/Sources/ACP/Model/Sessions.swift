public import JSONRPC

extension ACP {
    /// Name and version of a client or an agent.
    public struct Implementation: Codable, Hashable, Sendable {
        public var name: String
        public var title: String?
        public var version: String
        public var meta: Meta?

        public init(name: String, title: String? = nil, version: String, meta: Meta? = nil) {
            self.name = name
            self.title = title
            self.version = version
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case name, title, version
            case meta = "_meta"
        }
    }

    /// A session as listed by `session/list`.
    public struct SessionInfo: Codable, Hashable, Sendable {
        public var sessionId: SessionID
        public var cwd: String
        public var additionalDirectories: [String]?
        public var title: String?
        /// ISO 8601 timestamp.
        public var updatedAt: String?
        public var meta: Meta?

        public init(
            sessionId: SessionID,
            cwd: String,
            additionalDirectories: [String]? = nil,
            title: String? = nil,
            updatedAt: String? = nil,
            meta: Meta? = nil
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.additionalDirectories = additionalDirectories
            self.title = title
            self.updatedAt = updatedAt
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, cwd, additionalDirectories, title, updatedAt
            case meta = "_meta"
        }
    }

    public struct NameValue: Codable, Hashable, Sendable {
        public var name: String
        public var value: String
        public var meta: Meta?

        public init(name: String, value: String, meta: Meta? = nil) {
            self.name = name
            self.value = value
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case name, value
            case meta = "_meta"
        }
    }

    public typealias EnvVariable = NameValue
    public typealias HTTPHeader = NameValue

    public struct MCPServerStdio: Codable, Hashable, Sendable {
        public var name: String
        public var command: String
        public var args: [String]
        public var env: [EnvVariable]
        public var meta: Meta?

        public init(name: String, command: String, args: [String] = [], env: [EnvVariable] = [], meta: Meta? = nil) {
            self.name = name
            self.command = command
            self.args = args
            self.env = env
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case name, command, args, env
            case meta = "_meta"
        }
    }

    public struct MCPServerRemote: Codable, Hashable, Sendable {
        public var name: String
        public var url: String
        public var headers: [HTTPHeader]
        public var meta: Meta?

        public init(name: String, url: String, headers: [HTTPHeader] = [], meta: Meta? = nil) {
            self.name = name
            self.url = url
            self.headers = headers
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case name, url, headers
            case meta = "_meta"
        }
    }

    /// An MCP server the agent should connect to.
    public enum MCPServer: Codable, Hashable, Sendable {
        case stdio(MCPServerStdio)
        case http(MCPServerRemote)
        /// Deprecated in favor of HTTP.
        case sse(MCPServerRemote)
        case unknown(JSONValue)

        public init(from decoder: any Decoder) throws {
            switch try Tagged.tag(in: decoder, key: "type") {
            case nil: self = .stdio(try MCPServerStdio(from: decoder))
            case "http": self = .http(try MCPServerRemote(from: decoder))
            case "sse": self = .sse(try MCPServerRemote(from: decoder))
            default: self = .unknown(try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .stdio(let server): try server.encode(to: encoder)
            case .http(let server): try Tagged.encode(server, tag: "http", key: "type", to: encoder)
            case .sse(let server): try Tagged.encode(server, tag: "sse", key: "type", to: encoder)
            case .unknown(let raw): try raw.encode(to: encoder)
            }
        }
    }

    /// Authentication handled by the agent itself after `authenticate`.
    public struct AgentAuthMethod: Codable, Hashable, Sendable {
        public var id: AuthMethodID
        public var name: String
        public var description: String?
        public var meta: Meta?

        public init(id: AuthMethodID, name: String, description: String? = nil, meta: Meta? = nil) {
            self.id = id
            self.name = name
            self.description = description
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, description
            case meta = "_meta"
        }
    }

    /// Authentication by running the agent's command with these arguments in a real terminal.
    public struct TerminalAuthMethod: Codable, Hashable, Sendable {
        public var id: AuthMethodID
        public var name: String
        public var description: String?
        public var args: [String]?
        public var env: [String: String]?
        public var meta: Meta?

        public init(
            id: AuthMethodID,
            name: String,
            description: String? = nil,
            args: [String]? = nil,
            env: [String: String]? = nil,
            meta: Meta? = nil
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.args = args
            self.env = env
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, description, args, env
            case meta = "_meta"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            args = try? container.decodeIfPresent([String].self, forKey: .args)
            env = try? container.decodeIfPresent([String: String].self, forKey: .env)
            meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
        }
    }

    public enum AuthMethod: Codable, Hashable, Sendable {
        case agent(AgentAuthMethod)
        case terminal(TerminalAuthMethod)
        case unknown(JSONValue)

        public var id: AuthMethodID? {
            switch self {
            case .agent(let method): method.id
            case .terminal(let method): method.id
            case .unknown(let raw): raw["id"]?.stringValue
            }
        }

        public init(from decoder: any Decoder) throws {
            switch try Tagged.tag(in: decoder, key: "type") {
            case nil, "agent": self = .agent(try AgentAuthMethod(from: decoder))
            case "terminal": self = .terminal(try TerminalAuthMethod(from: decoder))
            default: self = .unknown(try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .agent(let method): try method.encode(to: encoder)
            case .terminal(let method): try Tagged.encode(method, tag: "terminal", key: "type", to: encoder)
            case .unknown(let raw): try raw.encode(to: encoder)
            }
        }
    }
}
