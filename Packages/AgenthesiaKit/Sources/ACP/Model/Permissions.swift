public import JSONRPC

extension ACP {
    public enum PermissionOptionKind: OpenEnum {
        case allowOnce, allowAlways, rejectOnce, rejectAlways
        case unknown(String)

        public static let knownCases: [PermissionOptionKind] = [.allowOnce, .allowAlways, .rejectOnce, .rejectAlways]

        public var rawValue: String {
            switch self {
            case .allowOnce: "allow_once"
            case .allowAlways: "allow_always"
            case .rejectOnce: "reject_once"
            case .rejectAlways: "reject_always"
            case .unknown(let value): value
            }
        }
    }

    public struct PermissionOption: Codable, Hashable, Sendable {
        public var optionId: PermissionOptionID
        public var name: String
        public var kind: PermissionOptionKind
        public var meta: Meta?

        public init(optionId: PermissionOptionID, name: String, kind: PermissionOptionKind, meta: Meta? = nil) {
            self.optionId = optionId
            self.name = name
            self.kind = kind
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case optionId, name, kind
            case meta = "_meta"
        }
    }

    /// The user's answer to a permission request.
    public enum PermissionOutcome: Codable, Hashable, Sendable {
        /// The prompt turn was cancelled before the user answered.
        case cancelled
        case selected(PermissionOptionID)
        case unknown(JSONValue)

        private enum CodingKeys: String, CodingKey {
            case outcome, optionId
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .outcome) {
            case "cancelled": self = .cancelled
            case "selected": self = .selected(try container.decode(String.self, forKey: .optionId))
            default: self = .unknown(try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .cancelled:
                try container.encode("cancelled", forKey: .outcome)
            case .selected(let optionID):
                try container.encode("selected", forKey: .outcome)
                try container.encode(optionID, forKey: .optionId)
            case .unknown(let raw):
                try raw.encode(to: encoder)
            }
        }
    }
}
