/// A string enumeration from the protocol that tolerates values it does not know.
///
/// Unknown values decode to `unknown(_:)` and encode back unchanged, so a newer agent never breaks
/// decoding.
public protocol OpenEnum: Codable, Hashable, Sendable {
    /// Every known case, used to map raw values back to cases.
    static var knownCases: [Self] { get }
    static func unknown(_ rawValue: String) -> Self
    var rawValue: String { get }
}

extension OpenEnum {
    public init(rawValue: String) {
        self = Self.knownCases.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
