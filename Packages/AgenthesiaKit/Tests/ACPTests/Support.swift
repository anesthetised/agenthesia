import ACP
import Foundation
import JSONRPC
import Testing

enum Fixtures {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    static func json(_ path: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appending(path: path)))
    }
}

/// Decodes `json` as `T`, re-encodes it and returns both.
func roundTrip<T: Codable>(_ type: T.Type, _ json: JSONValue) throws -> (value: T, encoded: JSONValue) {
    let value = try json.decode(as: T.self)
    return (value, try JSONValue(encoding: value))
}

/// Asserts that `json` decodes as `T` and encodes back to the same JSON.
@discardableResult
func expectRoundTrip<T: Codable>(
    _ type: T.Type,
    _ json: JSONValue,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
    let (value, encoded) = try roundTrip(type, json)
    #expect(encoded.normalized == json.normalized, sourceLocation: sourceLocation)
    return value
}

extension JSONValue {
    /// The value with `null` object members removed: an explicit `null` and an absent field are equivalent.
    var normalized: JSONValue {
        switch self {
        case .object(let object): .object(object.filter { !$0.value.isNull }.mapValues(\.normalized))
        case .array(let array): .array(array.map(\.normalized))
        default: self
        }
    }

    /// Compact JSON text, for failure messages.
    var compact: String {
        (try? JSONEncoder.rpc.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "<unencodable>"
    }
}
