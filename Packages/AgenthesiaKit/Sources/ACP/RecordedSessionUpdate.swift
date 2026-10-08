public import Foundation

extension ACP {
    /// Decodes an original session/update notification without a lossy typed re-encoding.
    /// Version-specific adapters still normalize the live delegate's update separately.
    public struct RecordedSessionUpdate: Sendable {
        public let sessionId: SessionID
        public let update: SessionUpdate

        public init(rawNotification: Data) throws {
            struct Envelope: Decodable {
                struct Params: Decodable {
                    var sessionId: SessionID
                    var update: SessionUpdate
                }
                var jsonrpc: String
                var method: String
                var params: Params
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: rawNotification)
            guard envelope.jsonrpc == "2.0", envelope.method == "session/update" else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a session update"))
            }
            sessionId = envelope.params.sessionId
            update = envelope.params.update
        }
    }
}
