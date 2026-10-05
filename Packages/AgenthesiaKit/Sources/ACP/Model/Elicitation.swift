public import JSONRPC

extension ACP {
    public enum StringFormat: OpenEnum {
        case email, uri, date, dateTime
        case unknown(String)

        public static let knownCases: [StringFormat] = [.email, .uri, .date, .dateTime]

        public var rawValue: String {
            switch self {
            case .email: "email"
            case .uri: "uri"
            case .date: "date"
            case .dateTime: "date-time"
            case .unknown(let value): value
            }
        }
    }

    /// A titled choice in an enumeration.
    public struct EnumOption: Codable, Hashable, Sendable {
        public var const: String
        public var title: String
        public var description: String?
        public var meta: Meta?

        public init(const: String, title: String, description: String? = nil, meta: Meta? = nil) {
            self.const = const
            self.title = title
            self.description = description
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case const, title, description
            case meta = "_meta"
        }
    }

    public struct StringPropertySchema: Codable, Hashable, Sendable {
        public var title: String?
        public var description: String?
        public var minLength: Int?
        public var maxLength: Int?
        public var pattern: String?
        public var format: StringFormat?
        public var `default`: String?
        public var `enum`: [String]?
        public var oneOf: [EnumOption]?
        public var meta: Meta?

        public init(
            title: String? = nil,
            description: String? = nil,
            minLength: Int? = nil,
            maxLength: Int? = nil,
            pattern: String? = nil,
            format: StringFormat? = nil,
            default: String? = nil,
            enum: [String]? = nil,
            oneOf: [EnumOption]? = nil,
            meta: Meta? = nil
        ) {
            self.title = title
            self.description = description
            self.minLength = minLength
            self.maxLength = maxLength
            self.pattern = pattern
            self.format = format
            self.default = `default`
            self.enum = `enum`
            self.oneOf = oneOf
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case title, description, minLength, maxLength, pattern, format, `default`, `enum`, oneOf
            case meta = "_meta"
        }
    }

    public struct NumberPropertySchema<Number: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
        public var title: String?
        public var description: String?
        public var minimum: Number?
        public var maximum: Number?
        public var `default`: Number?
        public var meta: Meta?

        public init(
            title: String? = nil,
            description: String? = nil,
            minimum: Number? = nil,
            maximum: Number? = nil,
            default: Number? = nil,
            meta: Meta? = nil
        ) {
            self.title = title
            self.description = description
            self.minimum = minimum
            self.maximum = maximum
            self.default = `default`
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case title, description, minimum, maximum, `default`
            case meta = "_meta"
        }
    }

    public struct BooleanPropertySchema: Codable, Hashable, Sendable {
        public var title: String?
        public var description: String?
        public var `default`: Bool?
        public var meta: Meta?

        public init(title: String? = nil, description: String? = nil, default: Bool? = nil, meta: Meta? = nil) {
            self.title = title
            self.description = description
            self.default = `default`
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case title, description, `default`
            case meta = "_meta"
        }
    }

    /// The choices of a multi-select property.
    public enum MultiSelectItems: Codable, Hashable, Sendable {
        case strings([String])
        case titled([EnumOption])
        case unknown(JSONValue)

        private enum CodingKeys: String, CodingKey {
            case type, `enum`, anyOf
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let options = try container.decodeIfPresent([EnumOption].self, forKey: .anyOf) {
                self = .titled(options)
            } else if try container.decodeIfPresent(String.self, forKey: .type) == "string" {
                self = .strings(try container.decode([String].self, forKey: .enum))
            } else {
                self = .unknown(try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .strings(let values):
                try container.encode("string", forKey: .type)
                try container.encode(values, forKey: .enum)
            case .titled(let options):
                try container.encode(options, forKey: .anyOf)
            case .unknown(let raw):
                try raw.encode(to: encoder)
            }
        }
    }

    public struct MultiSelectPropertySchema: Codable, Hashable, Sendable {
        public var title: String?
        public var description: String?
        public var minItems: Int?
        public var maxItems: Int?
        public var items: MultiSelectItems
        public var `default`: [String]?
        public var meta: Meta?

        public init(
            title: String? = nil,
            description: String? = nil,
            minItems: Int? = nil,
            maxItems: Int? = nil,
            items: MultiSelectItems,
            default: [String]? = nil,
            meta: Meta? = nil
        ) {
            self.title = title
            self.description = description
            self.minItems = minItems
            self.maxItems = maxItems
            self.items = items
            self.default = `default`
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case title, description, minItems, maxItems, items, `default`
            case meta = "_meta"
        }
    }

    /// A field of an elicitation form.
    public enum PropertySchema: Codable, Hashable, Sendable {
        case string(StringPropertySchema)
        case number(NumberPropertySchema<Double>)
        case integer(NumberPropertySchema<Int64>)
        case boolean(BooleanPropertySchema)
        case multiSelect(MultiSelectPropertySchema)
        case unknown(JSONValue)

        public init(from decoder: any Decoder) throws {
            switch try Tagged.tag(in: decoder, key: "type") {
            case "string": self = .string(try StringPropertySchema(from: decoder))
            case "number": self = .number(try NumberPropertySchema(from: decoder))
            case "integer": self = .integer(try NumberPropertySchema(from: decoder))
            case "boolean": self = .boolean(try BooleanPropertySchema(from: decoder))
            case "array": self = .multiSelect(try MultiSelectPropertySchema(from: decoder))
            default: self = .unknown(try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .string(let schema): try Tagged.encode(schema, tag: "string", key: "type", to: encoder)
            case .number(let schema): try Tagged.encode(schema, tag: "number", key: "type", to: encoder)
            case .integer(let schema): try Tagged.encode(schema, tag: "integer", key: "type", to: encoder)
            case .boolean(let schema): try Tagged.encode(schema, tag: "boolean", key: "type", to: encoder)
            case .multiSelect(let schema): try Tagged.encode(schema, tag: "array", key: "type", to: encoder)
            case .unknown(let raw): try raw.encode(to: encoder)
            }
        }
    }

    /// A flat form: an object whose properties are primitive fields.
    public struct ElicitationSchema: Codable, Hashable, Sendable {
        public var title: String?
        public var description: String?
        public var properties: [String: PropertySchema]
        public var required: [String]?
        public var meta: Meta?

        public init(
            title: String? = nil,
            description: String? = nil,
            properties: [String: PropertySchema] = [:],
            required: [String]? = nil,
            meta: Meta? = nil
        ) {
            self.title = title
            self.description = description
            self.properties = properties
            self.required = required
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case type, title, description, properties, required
            case meta = "_meta"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            properties = try container.decodeIfPresent([String: PropertySchema].self, forKey: .properties) ?? [:]
            required = try container.decodeIfPresent([String].self, forKey: .required)
            meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("object", forKey: .type)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encode(properties, forKey: .properties)
            try container.encodeIfPresent(required, forKey: .required)
            try container.encodeIfPresent(meta, forKey: .meta)
        }
    }

    /// A request for structured input from the user.
    public struct ElicitationRequest: Codable, Hashable, Sendable {
        public enum Mode: Hashable, Sendable {
            /// Show a form and return the values.
            case form(ElicitationSchema)
            /// Open a URL; the agent sends `elicitation/complete` when the flow finishes.
            case url(elicitationId: ElicitationID, url: String)
            case unknown(String)
        }

        /// What the elicitation belongs to.
        public enum Scope: Hashable, Sendable {
            case session(SessionID, toolCallId: ToolCallID?)
            case request(RequestID)
        }

        public var message: String
        public var mode: Mode
        public var scope: Scope
        public var meta: Meta?

        public init(message: String, mode: Mode, scope: Scope, meta: Meta? = nil) {
            self.message = message
            self.mode = mode
            self.scope = scope
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case message, mode, requestedSchema, elicitationId, url, sessionId, toolCallId, requestId
            case meta = "_meta"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decode(String.self, forKey: .message)
            meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
            switch try container.decode(String.self, forKey: .mode) {
            case "form":
                mode = .form(try container.decode(ElicitationSchema.self, forKey: .requestedSchema))
            case "url":
                mode = .url(
                    elicitationId: try container.decode(String.self, forKey: .elicitationId),
                    url: try container.decode(String.self, forKey: .url)
                )
            case let other:
                mode = .unknown(other)
            }
            if let sessionID = try container.decodeIfPresent(String.self, forKey: .sessionId) {
                scope = .session(sessionID, toolCallId: try container.decodeIfPresent(String.self, forKey: .toolCallId))
            } else {
                scope = .request(try container.decode(RequestID.self, forKey: .requestId))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(meta, forKey: .meta)
            switch mode {
            case .form(let schema):
                try container.encode("form", forKey: .mode)
                try container.encode(schema, forKey: .requestedSchema)
            case .url(let elicitationID, let url):
                try container.encode("url", forKey: .mode)
                try container.encode(elicitationID, forKey: .elicitationId)
                try container.encode(url, forKey: .url)
            case .unknown(let mode):
                try container.encode(mode, forKey: .mode)
            }
            switch scope {
            case .session(let sessionID, let toolCallID):
                try container.encode(sessionID, forKey: .sessionId)
                try container.encodeIfPresent(toolCallID, forKey: .toolCallId)
            case .request(let requestID):
                try container.encode(requestID, forKey: .requestId)
            }
        }
    }

    /// The user's answer to an elicitation.
    public struct ElicitationResponse: Codable, Hashable, Sendable {
        public enum Action: Hashable, Sendable {
            /// Submitted, with the form values keyed by property name.
            case accept([String: JSONValue]?)
            case decline
            case cancel
            case unknown(String)
        }

        public var action: Action
        public var meta: Meta?

        public init(action: Action, meta: Meta? = nil) {
            self.action = action
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case action, content
            case meta = "_meta"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
            switch try container.decode(String.self, forKey: .action) {
            case "accept": action = .accept(try container.decodeIfPresent([String: JSONValue].self, forKey: .content))
            case "decline": action = .decline
            case "cancel": action = .cancel
            case let other: action = .unknown(other)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(meta, forKey: .meta)
            switch action {
            case .accept(let content):
                try container.encode("accept", forKey: .action)
                try container.encodeIfPresent(content, forKey: .content)
            case .decline: try container.encode("decline", forKey: .action)
            case .cancel: try container.encode("cancel", forKey: .action)
            case .unknown(let action): try container.encode(action, forKey: .action)
            }
        }
    }

    /// Sent by the agent when a URL elicitation finished.
    public struct ElicitationComplete: Codable, Hashable, Sendable {
        public var elicitationId: ElicitationID
        public var meta: Meta?

        public init(elicitationId: ElicitationID, meta: Meta? = nil) {
            self.elicitationId = elicitationId
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case elicitationId
            case meta = "_meta"
        }
    }
}
