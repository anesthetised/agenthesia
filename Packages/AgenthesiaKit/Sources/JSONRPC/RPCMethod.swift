/// A typed JSON-RPC request: its method name, parameters and result.
public protocol RPCRequest: Sendable {
    associatedtype Params: Codable & Sendable
    associatedtype Result: Codable & Sendable
    static var method: String { get }
}

/// A typed JSON-RPC notification: its method name and parameters.
public protocol RPCNotification: Sendable {
    associatedtype Params: Codable & Sendable
    static var method: String { get }
}

extension JSONRPC {
    /// An empty object, for requests without parameters or results.
    public struct Empty: Codable, Sendable, Hashable {
        public init() {}
    }
}
