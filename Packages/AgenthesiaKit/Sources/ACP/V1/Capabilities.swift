extension ACP.V1 {
    public typealias Meta = ACP.Meta
    public typealias Capability = ACP.Capability

    public struct FileSystemCapabilities: Codable, Hashable, Sendable {
        public var readTextFile: Bool?
        public var writeTextFile: Bool?
        public var meta: Meta?

        public init(readTextFile: Bool? = nil, writeTextFile: Bool? = nil, meta: Meta? = nil) {
            self.readTextFile = readTextFile
            self.writeTextFile = writeTextFile
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case readTextFile, writeTextFile
            case meta = "_meta"
        }
    }

    public struct ConfigOptionsCapabilities: Codable, Hashable, Sendable {
        /// Present when the client supports boolean config options.
        public var boolean: Capability?
        public var meta: Meta?

        public init(boolean: Capability? = nil, meta: Meta? = nil) {
            self.boolean = boolean
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case boolean
            case meta = "_meta"
        }
    }

    public struct ClientSessionCapabilities: Codable, Hashable, Sendable {
        public var configOptions: ConfigOptionsCapabilities?
        public var meta: Meta?

        public init(configOptions: ConfigOptionsCapabilities? = nil, meta: Meta? = nil) {
            self.configOptions = configOptions
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case configOptions
            case meta = "_meta"
        }
    }

    public struct ClientAuthCapabilities: Codable, Hashable, Sendable {
        /// Whether the client can run terminal auth methods.
        public var terminal: Bool?
        public var meta: Meta?

        public init(terminal: Bool? = nil, meta: Meta? = nil) {
            self.terminal = terminal
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case terminal
            case meta = "_meta"
        }
    }

    public struct ElicitationCapabilities: Codable, Hashable, Sendable {
        public var form: Capability?
        public var url: Capability?
        public var meta: Meta?

        public init(form: Capability? = nil, url: Capability? = nil, meta: Meta? = nil) {
            self.form = form
            self.url = url
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case form, url
            case meta = "_meta"
        }
    }

    public struct ClientCapabilities: Codable, Hashable, Sendable {
        public var fs: FileSystemCapabilities?
        public var terminal: Bool?
        public var session: ClientSessionCapabilities?
        public var auth: ClientAuthCapabilities?
        public var elicitation: ElicitationCapabilities?
        public var meta: Meta?

        public init(
            fs: FileSystemCapabilities? = nil,
            terminal: Bool? = nil,
            session: ClientSessionCapabilities? = nil,
            auth: ClientAuthCapabilities? = nil,
            elicitation: ElicitationCapabilities? = nil,
            meta: Meta? = nil
        ) {
            self.fs = fs
            self.terminal = terminal
            self.session = session
            self.auth = auth
            self.elicitation = elicitation
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case fs, terminal, session, auth, elicitation
            case meta = "_meta"
        }
    }

    public struct PromptCapabilities: Codable, Hashable, Sendable {
        public var image: Bool?
        public var audio: Bool?
        public var embeddedContext: Bool?
        public var meta: Meta?

        public init(image: Bool? = nil, audio: Bool? = nil, embeddedContext: Bool? = nil, meta: Meta? = nil) {
            self.image = image
            self.audio = audio
            self.embeddedContext = embeddedContext
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case image, audio, embeddedContext
            case meta = "_meta"
        }
    }

    public struct MCPCapabilities: Codable, Hashable, Sendable {
        public var http: Bool?
        public var sse: Bool?
        public var meta: Meta?

        public init(http: Bool? = nil, sse: Bool? = nil, meta: Meta? = nil) {
            self.http = http
            self.sse = sse
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case http, sse
            case meta = "_meta"
        }
    }

    public struct SessionCapabilities: Codable, Hashable, Sendable {
        public var list: Capability?
        public var delete: Capability?
        public var additionalDirectories: Capability?
        public var resume: Capability?
        public var close: Capability?
        public var meta: Meta?

        public init(
            list: Capability? = nil,
            delete: Capability? = nil,
            additionalDirectories: Capability? = nil,
            resume: Capability? = nil,
            close: Capability? = nil,
            meta: Meta? = nil
        ) {
            self.list = list
            self.delete = delete
            self.additionalDirectories = additionalDirectories
            self.resume = resume
            self.close = close
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case list, delete, additionalDirectories, resume, close
            case meta = "_meta"
        }
    }

    public struct AgentAuthCapabilities: Codable, Hashable, Sendable {
        public var logout: Capability?
        public var meta: Meta?

        public init(logout: Capability? = nil, meta: Meta? = nil) {
            self.logout = logout
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case logout
            case meta = "_meta"
        }
    }

    public struct AgentCapabilities: Codable, Hashable, Sendable {
        public var loadSession: Bool?
        public var promptCapabilities: PromptCapabilities?
        public var mcpCapabilities: MCPCapabilities?
        public var sessionCapabilities: SessionCapabilities?
        public var auth: AgentAuthCapabilities?
        public var meta: Meta?

        public init(
            loadSession: Bool? = nil,
            promptCapabilities: PromptCapabilities? = nil,
            mcpCapabilities: MCPCapabilities? = nil,
            sessionCapabilities: SessionCapabilities? = nil,
            auth: AgentAuthCapabilities? = nil,
            meta: Meta? = nil
        ) {
            self.loadSession = loadSession
            self.promptCapabilities = promptCapabilities
            self.mcpCapabilities = mcpCapabilities
            self.sessionCapabilities = sessionCapabilities
            self.auth = auth
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case loadSession, promptCapabilities, mcpCapabilities, sessionCapabilities, auth
            case meta = "_meta"
        }
    }
}
