/// The identifier of a JSON-RPC request.
public enum RequestID: Sendable, Hashable, Codable, CustomStringConvertible {
    case int(Int64)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int64.self) {
            self = .int(int)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let int): try container.encode(int)
        case .string(let string): try container.encode(string)
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case .int(let int): .int(int)
        case .string(let string): .string(string)
        }
    }

    public var description: String {
        switch self {
        case .int(let int): String(int)
        case .string(let string): string
        }
    }
}
