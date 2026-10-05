/// A JSON-RPC 2.0 message.
public enum Message: Sendable, Equatable {
    case request(id: RequestID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    /// A response. `id` is `nil` only for errors about messages whose id could not be determined.
    case response(id: RequestID?, result: Result<JSONValue, RPCError>)
}

extension Message: Codable {
    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .jsonrpc)
        guard version == JSONRPC.version else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc,
                in: container,
                debugDescription: "Unsupported JSON-RPC version \(version)"
            )
        }
        if let method = try container.decodeIfPresent(String.self, forKey: .method) {
            let params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
            if let id = try container.decodeIfPresent(RequestID.self, forKey: .id) {
                self = .request(id: id, method: method, params: params)
            } else {
                self = .notification(method: method, params: params)
            }
        } else if container.contains(.error) {
            let id = try container.decodeIfPresent(RequestID.self, forKey: .id)
            self = .response(id: id, result: .failure(try container.decode(RPCError.self, forKey: .error)))
        } else if container.contains(.result) {
            let id = try container.decode(RequestID.self, forKey: .id)
            let result = try container.decodeIfPresent(JSONValue.self, forKey: .result) ?? .null
            self = .response(id: id, result: .success(result))
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Neither a request, a notification nor a response")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(JSONRPC.version, forKey: .jsonrpc)
        switch self {
        case .request(let id, let method, let params):
            try container.encode(id, forKey: .id)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        case .notification(let method, let params):
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        case .response(let id, .success(let result)):
            try container.encode(id, forKey: .id)
            try container.encode(result, forKey: .result)
        case .response(let id, .failure(let error)):
            if let id {
                try container.encode(id, forKey: .id)
            } else {
                try container.encodeNil(forKey: .id)
            }
            try container.encode(error, forKey: .error)
        }
    }
}
