public import JSONRPC

/// A scripted conversation, played by `ScenarioAgent` from the agent's side.
///
/// Scenarios are `Codable`, so they can be written in Swift or loaded from JSON:
///
/// ```json
/// {"steps": [
///   {"step": "expectRequest", "method": "initialize", "params": {"protocolVersion": 1},
///    "result": {"protocolVersion": 1}},
///   {"step": "expectRequest", "method": "session/prompt", "deferAs": "prompt"},
///   {"step": "sendNotification", "method": "session/update", "params": {...}},
///   {"step": "respond", "to": "prompt", "result": {"stopReason": "end_turn"}}
/// ]}
/// ```
public struct Scenario: Codable, Sendable {
    public var steps: [Step]

    public init(_ steps: [Step]) {
        self.steps = steps
    }

    public enum Response: Sendable, Equatable {
        case result(JSONValue)
        case error(RPCError)
    }

    public enum Step: Sendable, Equatable {
        /// The next message from the client must be this request; `params` must be contained in its params.
        /// Replies with `response`, or remembers the request as `deferAs` to reply later with `respond`.
        case expectRequest(method: String, params: JSONValue? = nil, response: Response?, deferAs: String? = nil)
        /// The next message from the client must be this notification.
        case expectNotification(method: String, params: JSONValue? = nil)
        /// Replies to a request remembered by `expectRequest(deferAs:)`.
        case respond(to: String, response: Response)
        case sendNotification(method: String, params: JSONValue?)
        /// Sends a request and waits for the client's response, which must contain `expect` if given.
        case sendRequest(method: String, params: JSONValue?, expect: Response? = nil)
        case delay(milliseconds: Int)
    }
}

extension Scenario.Step: Codable {
    private enum CodingKeys: String, CodingKey {
        case step, method, params, result, error, deferAs, to, milliseconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func response() throws -> Scenario.Response? {
            if let error = try container.decodeIfPresent(RPCError.self, forKey: .error) {
                return .error(error)
            }
            return try container.decodeIfPresent(JSONValue.self, forKey: .result).map(Scenario.Response.result)
        }
        let step = try container.decode(String.self, forKey: .step)
        switch step {
        case "expectRequest":
            self = .expectRequest(
                method: try container.decode(String.self, forKey: .method),
                params: try container.decodeIfPresent(JSONValue.self, forKey: .params),
                response: try response(),
                deferAs: try container.decodeIfPresent(String.self, forKey: .deferAs)
            )
        case "expectNotification":
            self = .expectNotification(
                method: try container.decode(String.self, forKey: .method),
                params: try container.decodeIfPresent(JSONValue.self, forKey: .params)
            )
        case "respond":
            guard let response = try response() else {
                throw DecodingError.dataCorruptedError(
                    forKey: .result,
                    in: container,
                    debugDescription: "Missing result"
                )
            }
            self = .respond(to: try container.decode(String.self, forKey: .to), response: response)
        case "sendNotification":
            self = .sendNotification(
                method: try container.decode(String.self, forKey: .method),
                params: try container.decodeIfPresent(JSONValue.self, forKey: .params)
            )
        case "sendRequest":
            self = .sendRequest(
                method: try container.decode(String.self, forKey: .method),
                params: try container.decodeIfPresent(JSONValue.self, forKey: .params),
                expect: try response()
            )
        case "delay":
            self = .delay(milliseconds: try container.decode(Int.self, forKey: .milliseconds))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .step,
                in: container,
                debugDescription: "Unknown step \(step)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func encode(_ response: Scenario.Response?) throws {
            switch response {
            case .result(let result): try container.encode(result, forKey: .result)
            case .error(let error): try container.encode(error, forKey: .error)
            case nil: break
            }
        }
        switch self {
        case .expectRequest(let method, let params, let response, let deferAs):
            try container.encode("expectRequest", forKey: .step)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
            try encode(response)
            try container.encodeIfPresent(deferAs, forKey: .deferAs)
        case .expectNotification(let method, let params):
            try container.encode("expectNotification", forKey: .step)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        case .respond(let to, let response):
            try container.encode("respond", forKey: .step)
            try container.encode(to, forKey: .to)
            try encode(response)
        case .sendNotification(let method, let params):
            try container.encode("sendNotification", forKey: .step)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        case .sendRequest(let method, let params, let expect):
            try container.encode("sendRequest", forKey: .step)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
            try encode(expect)
        case .delay(let milliseconds):
            try container.encode("delay", forKey: .step)
            try container.encode(milliseconds, forKey: .milliseconds)
        }
    }
}
