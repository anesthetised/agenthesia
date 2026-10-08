public import Foundation
import JSONRPC

extension ACP {
    /// Decodes an original session/update notification without a lossy typed re-encoding.
    /// Version-specific adapters still normalize the live delegate's update separately.
    public struct RecordedSessionUpdate: Sendable {
        public let sessionId: SessionID
        public let update: SessionUpdate
        public let meta: Meta?
        let hadSchemaMismatch: Bool

        public init(rawNotification: Data) throws {
            struct Envelope: Decodable {
                struct Params: Decodable {
                    var sessionId: SessionID
                    var update: SessionUpdate
                    var meta: Meta?
                    var hadSchemaMismatch = false

                    private enum CodingKeys: String, CodingKey {
                        case sessionId, update
                        case meta = "_meta"
                    }

                    init(from decoder: any Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        sessionId = try container.decode(SessionID.self, forKey: .sessionId)
                        do {
                            update = try container.decode(SessionUpdate.self, forKey: .update)
                        } catch {
                            hadSchemaMismatch = true
                            // Recording must survive schema mismatches. The strict wire model is unchanged.
                            update = .unknown(try container.decodeIfPresent(JSONValue.self, forKey: .update) ?? .null)
                        }
                        meta = try? container.decodeIfPresent(Meta.self, forKey: .meta)
                    }
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
            meta = envelope.params.meta
            hadSchemaMismatch = envelope.params.hadSchemaMismatch
        }
    }
}
