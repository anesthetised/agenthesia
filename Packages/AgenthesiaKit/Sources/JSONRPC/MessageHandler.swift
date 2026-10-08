public import Foundation

/// Handles requests and notifications arriving on a `Connection`.
public protocol MessageHandler: Sendable {
    /// Handles a request and returns its result. Throw an `RPCError` to reply with a specific error.
    @concurrent func handleRequest(method: String, params: JSONValue?) async throws -> JSONValue

    /// Handles a notification.
    @concurrent func handleNotification(method: String, params: JSONValue?) async

    /// The original wire message, without its line terminator, for lossless event recording.
    @concurrent func handleNotification(method: String, params: JSONValue?, rawMessage: Data) async
}

extension MessageHandler {
    @concurrent public func handleNotification(method: String, params: JSONValue?, rawMessage: Data) async {
        await handleNotification(method: method, params: params)
    }
}

/// A `MessageHandler` that dispatches typed requests and notifications to registered closures.
///
/// Unknown requests are answered with `-32601`; unknown notifications are ignored, as JSON-RPC requires.
/// Parameters that fail to decode are answered with `-32602`.
public struct Router: MessageHandler {
    public typealias RequestHandler = @Sendable (JSONValue?) async throws -> JSONValue
    public typealias NotificationHandler = @Sendable (JSONValue?) async -> Void

    private var requests: [String: RequestHandler] = [:]
    private var notifications: [String: NotificationHandler] = [:]
    private var rawNotifications: [String: @Sendable (JSONValue?, Data) async -> Void] = [:]

    public init() {}

    /// The methods with a registered request handler.
    public var requestMethods: Set<String> { Set(requests.keys) }

    /// The methods with a registered notification handler.
    public var notificationMethods: Set<String> { Set(notifications.keys).union(rawNotifications.keys) }

    public mutating func on<R: RPCRequest>(
        _ request: R.Type,
        _ handler: @escaping @Sendable (R.Params) async throws -> R.Result
    ) {
        requests[R.method] = { params in
            let decoded: R.Params = try Self.decodeParams(params)
            return try JSONValue(encoding: try await handler(decoded))
        }
    }

    public mutating func on<N: RPCNotification>(
        _ notification: N.Type,
        _ handler: @escaping @Sendable (N.Params) async -> Void
    ) {
        notifications[N.method] = { params in
            guard let decoded: N.Params = try? Self.decodeParams(params) else {
                Log.connection.error("Dropping \(N.method, privacy: .public): invalid params")
                return
            }
            await handler(decoded)
        }
    }

    @concurrent public func handleRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        guard let handler = requests[method] else {
            throw RPCError.methodNotFound(method)
        }
        return try await handler(params)
    }

    /// Registers a lossless handler alongside the usual typed notification handler.
    public mutating func onRawNotification<N: RPCNotification>(
        _ notification: N.Type,
        _ handler: @escaping @Sendable (N.Params, Data) async -> Void
    ) {
        rawNotifications[N.method] = { params, rawMessage in
            guard let decoded: N.Params = try? Self.decodeParams(params) else { return }
            await handler(decoded, rawMessage)
        }
    }

    @concurrent public func handleNotification(method: String, params: JSONValue?, rawMessage: Data) async {
        if let handler = rawNotifications[method] {
            await handler(params, rawMessage)
        } else {
            await handleNotification(method: method, params: params)
        }
    }

    @concurrent public func handleNotification(method: String, params: JSONValue?) async {
        await notifications[method]?(params)
    }

    private static func decodeParams<T: Decodable>(_ params: JSONValue?) throws -> T {
        do {
            return try (params ?? .object([:])).decode(as: T.self)
        } catch {
            throw RPCError.invalidParams(String(describing: error))
        }
    }
}
