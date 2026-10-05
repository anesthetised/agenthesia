import JSONRPC

/// Helpers for tagged unions whose tag is a property next to the payload's own properties.
enum Tagged {
    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// The value of the tag property, or `nil` if it is absent.
    static func tag(in decoder: any Decoder, key: String) throws -> String? {
        try decoder.container(keyedBy: Key.self).decodeIfPresent(String.self, forKey: Key(key))
    }

    /// Whether the object has a property named `key`.
    static func has(_ key: String, in decoder: any Decoder) -> Bool {
        (try? decoder.container(keyedBy: Key.self).contains(Key(key))) ?? false
    }

    /// Encodes `payload` and adds the tag property.
    static func encode(_ payload: some Encodable, tag: String, key: String, to encoder: any Encoder) throws {
        try payload.encode(to: encoder)
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(tag, forKey: Key(key))
    }
}
