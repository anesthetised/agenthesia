public import Foundation

/// An arbitrary JSON value.
///
/// Integers and floating-point numbers are kept apart so that integer values survive a round trip.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    /// Converts any `Encodable` value into a `JSONValue`.
    public init(encoding value: some Encodable) throws {
        let data = try JSONEncoder.rpc.encode(value)
        self = try JSONDecoder.rpc.decode(JSONValue.self, from: data)
    }

    /// Decodes this value as `T`.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSONDecoder.rpc.decode(T.self, from: JSONEncoder.rpc.encode(self))
    }

    public var isNull: Bool {
        if case .null = self { true } else { false }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { object } else { nil }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { array } else { nil }
    }

    public var stringValue: String? {
        if case .string(let string) = self { string } else { nil }
    }

    public var intValue: Int64? {
        if case .int(let int) = self { int } else { nil }
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { bool } else { nil }
    }

    /// The value for `key` if this is an object, otherwise `nil`.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int64.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .int(let int): try container.encode(int)
        case .double(let double): try container.encode(double)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONEncoder {
    /// The encoder used for JSON-RPC messages: compact output, so a message never contains a newline.
    public static var rpc: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    /// The decoder used for JSON-RPC messages.
    public static var rpc: JSONDecoder { JSONDecoder() }
}
