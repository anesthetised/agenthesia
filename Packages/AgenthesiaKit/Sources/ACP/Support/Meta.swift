public import JSONRPC

extension ACP {
    /// Extension data carried in `_meta`. Keys `traceparent`, `tracestate` and `baggage` are reserved.
    public typealias Meta = [String: JSONValue]

    /// A capability that is either absent or present (as an object that may only carry `_meta`).
    public struct Capability: Codable, Hashable, Sendable {
        public var meta: Meta?

        public init(meta: Meta? = nil) {
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case meta = "_meta"
        }
    }
}
