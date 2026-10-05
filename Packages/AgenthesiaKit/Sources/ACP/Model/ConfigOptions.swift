public import JSONRPC

extension ACP {
    public enum ConfigOptionCategory: OpenEnum {
        case mode, model, modelConfig, thoughtLevel
        case unknown(String)

        public static let knownCases: [ConfigOptionCategory] = [.mode, .model, .modelConfig, .thoughtLevel]

        public var rawValue: String {
            switch self {
            case .mode: "mode"
            case .model: "model"
            case .modelConfig: "model_config"
            case .thoughtLevel: "thought_level"
            case .unknown(let value): value
            }
        }
    }

    public struct ConfigSelectOption: Codable, Hashable, Sendable {
        public var value: ConfigValueID
        public var name: String
        public var description: String?
        public var meta: Meta?

        public init(value: ConfigValueID, name: String, description: String? = nil, meta: Meta? = nil) {
            self.value = value
            self.name = name
            self.description = description
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case value, name, description
            case meta = "_meta"
        }
    }

    public struct ConfigSelectGroup: Codable, Hashable, Sendable {
        public var group: String
        public var name: String
        public var options: [ConfigSelectOption]
        public var meta: Meta?

        public init(group: String, name: String, options: [ConfigSelectOption], meta: Meta? = nil) {
            self.group = group
            self.name = name
            self.options = options
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case group, name, options
            case meta = "_meta"
        }
    }

    /// The choices of a select option: a flat list or named groups.
    public enum ConfigSelectOptions: Codable, Hashable, Sendable {
        case flat([ConfigSelectOption])
        case grouped([ConfigSelectGroup])

        public init(from decoder: any Decoder) throws {
            let raw = try [JSONValue](from: decoder)
            if raw.contains(where: { $0["group"] != nil }) {
                self = .grouped(try JSONValue.array(raw).decode(as: [ConfigSelectGroup].self))
            } else {
                self = .flat(try JSONValue.array(raw).decode(as: [ConfigSelectOption].self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .flat(let options): try options.encode(to: encoder)
            case .grouped(let groups): try groups.encode(to: encoder)
            }
        }

        /// All choices, regardless of grouping.
        public var allOptions: [ConfigSelectOption] {
            switch self {
            case .flat(let options): options
            case .grouped(let groups): groups.flatMap(\.options)
            }
        }
    }

    /// A session setting the agent exposes, such as the model or the mode.
    public struct ConfigOption: Codable, Hashable, Sendable {
        public enum Value: Hashable, Sendable {
            case select(currentValue: ConfigValueID, options: ConfigSelectOptions)
            case boolean(currentValue: Bool)
            /// An option type this client does not know. Clients should not show it.
            case unknown(type: String, raw: JSONValue)
        }

        public var id: ConfigOptionID
        public var name: String
        public var description: String?
        public var category: ConfigOptionCategory?
        public var value: Value
        public var meta: Meta?

        public init(
            id: ConfigOptionID,
            name: String,
            description: String? = nil,
            category: ConfigOptionCategory? = nil,
            value: Value,
            meta: Meta? = nil
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.category = category
            self.value = value
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, description, category, type, currentValue, options
            case meta = "_meta"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            category = try? container.decodeIfPresent(ConfigOptionCategory.self, forKey: .category)
            meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
            switch try container.decode(String.self, forKey: .type) {
            case "select":
                value = .select(
                    currentValue: try container.decode(String.self, forKey: .currentValue),
                    options: try container.decode(ConfigSelectOptions.self, forKey: .options)
                )
            case "boolean":
                value = .boolean(currentValue: try container.decode(Bool.self, forKey: .currentValue))
            case let type:
                value = .unknown(type: type, raw: try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            if case .unknown(_, let raw) = value {
                try raw.encode(to: encoder)
                return
            }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(category, forKey: .category)
            try container.encodeIfPresent(meta, forKey: .meta)
            switch value {
            case .select(let currentValue, let options):
                try container.encode("select", forKey: .type)
                try container.encode(currentValue, forKey: .currentValue)
                try container.encode(options, forKey: .options)
            case .boolean(let currentValue):
                try container.encode("boolean", forKey: .type)
                try container.encode(currentValue, forKey: .currentValue)
            case .unknown:
                break
            }
        }
    }

    /// A new value for a config option.
    public enum ConfigValue: Hashable, Sendable {
        case select(ConfigValueID)
        case boolean(Bool)
    }
}
