/// A JSON-RPC error object. Also thrown by request handlers to reply with a specific error.
public struct RPCError: Error, Sendable, Hashable, Codable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

extension RPCError {
    public static let parseErrorCode = -32700
    public static let invalidRequestCode = -32600
    public static let methodNotFoundCode = -32601
    public static let invalidParamsCode = -32602
    public static let internalErrorCode = -32603
    public static let requestCancelledCode = -32800
    public static let authRequiredCode = -32000
    public static let resourceNotFoundCode = -32002

    public static func parseError(_ message: String = "Parse error") -> RPCError {
        RPCError(code: parseErrorCode, message: message)
    }

    public static func invalidRequest(_ message: String = "Invalid request") -> RPCError {
        RPCError(code: invalidRequestCode, message: message)
    }

    public static func methodNotFound(_ method: String) -> RPCError {
        RPCError(code: methodNotFoundCode, message: "Method not found: \(method)")
    }

    public static func invalidParams(_ message: String = "Invalid params") -> RPCError {
        RPCError(code: invalidParamsCode, message: message)
    }

    public static func internalError(_ message: String = "Internal error") -> RPCError {
        RPCError(code: internalErrorCode, message: message)
    }

    public static func requestCancelled(_ message: String = "Request cancelled") -> RPCError {
        RPCError(code: requestCancelledCode, message: message)
    }
}

/// Errors raised by a `Connection` itself rather than by the remote side.
public enum ConnectionError: Error, Sendable, Equatable {
    /// The connection was closed before a response arrived.
    case closed
    /// The peer's result did not match the expected type.
    case invalidResult(method: String, reason: String)
}
