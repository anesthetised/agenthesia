public import Foundation

/// The direction of a message, as seen by a `Connection`.
public enum TrafficDirection: Sendable {
    case incoming
    case outgoing
}

/// A JSON-RPC 2.0 peer over a `MessageTransport`.
///
/// Incoming messages are processed strictly in arrival order: a notification handler finishes before the
/// next message is looked at, so anything a request refers to has already been handled when the request
/// handler starts. Request handlers then run concurrently.
public actor Connection {
    public typealias TrafficObserver = @Sendable (TrafficDirection, Data) -> Void

    private let transport: any MessageTransport
    private let traffic: TrafficObserver?
    private let outgoing: AsyncStream<Data>.Continuation
    private let outgoingMessages: AsyncStream<Data>

    private var nextID: Int64 = 1
    private struct Pending {
        let succeed: @Sendable (JSONValue) async -> Void
        let fail: @Sendable (any Error) -> Void
    }

    private var pending: [RequestID: Pending] = [:]
    private var inFlight: [RequestID: Task<Void, Never>] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var isClosed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(transport: any MessageTransport, traffic: TrafficObserver? = nil) {
        self.transport = transport
        self.traffic = traffic
        (outgoingMessages, outgoing) = AsyncStream<Data>.makeStream()
    }

    /// Starts reading and writing. Incoming requests and notifications go to `handler`.
    public func start(handler: some MessageHandler) {
        let transport = transport
        let outgoingMessages = outgoingMessages
        let traffic = traffic
        tasks.append(
            Task {
                for await message in outgoingMessages {
                    traffic?(.outgoing, message)
                    do {
                        try await transport.send(message)
                    } catch {
                        self.shutDown()
                        return
                    }
                }
            }
        )
        tasks.append(
            Task {
                do {
                    for try await message in transport.messages {
                        traffic?(.incoming, message)
                        await self.receive(message, handler: handler)
                    }
                } catch {
                    Log.connection.error("Transport failed: \(error, privacy: .public)")
                }
                self.shutDown()
            }
        )
    }

    /// Sends a typed request and waits for its result.
    public func request<R: RPCRequest>(_ request: R.Type, _ params: R.Params) async throws -> R.Result {
        try await self.request(request, params, consuming: { $0 })
    }

    /// Consumes a decoded response before dispatching the next incoming message.
    /// Once admitted, consumption finishes even if the waiting task is cancelled or the connection closes.
    /// The consumer may close this connection, but must not await another wire response from it.
    public func request<R: RPCRequest, Value: Sendable>(
        _ request: R.Type,
        _ params: R.Params,
        consuming: @escaping @Sendable (R.Result) async throws -> Value
    ) async throws -> Value {
        try await performRequest(method: R.method, params: try JSONValue(encoding: params)) { raw in
            let result: R.Result
            do { result = try raw.decode(as: R.Result.self) } catch {
                throw ConnectionError.invalidResult(method: R.method, reason: String(describing: error))
            }
            return try await consuming(result)
        }
    }

    /// Sends a request and waits for its result.
    ///
    /// Cancelling the calling task before response admission sends `$/cancel_request` and throws.
    public func request(method: String, params: JSONValue?) async throws -> JSONValue {
        try await performRequest(method: method, params: params, consuming: { $0 })
    }

    private func performRequest<Value: Sendable>(
        method: String,
        params: JSONValue?,
        consuming: @escaping @Sendable (JSONValue) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !isClosed else { throw ConnectionError.closed }
        let id = RequestID.int(nextID)
        nextID += 1
        let message = try JSONEncoder.rpc.encode(Message.request(id: id, method: method, params: params))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(
                    succeed: { raw in
                        do { continuation.resume(returning: try await consuming(raw)) } catch {
                            continuation.resume(throwing: error)
                        }
                    },
                    fail: { continuation.resume(throwing: $0) }
                )
                outgoing.yield(message)
            }
        } onCancel: {
            Task { await self.cancelOutgoing(id) }
        }
    }

    /// Sends a typed notification.
    public func notify<N: RPCNotification>(_ notification: N.Type, _ params: N.Params) throws {
        try notify(method: N.method, params: try JSONValue(encoding: params))
    }

    /// Sends a notification.
    public func notify(method: String, params: JSONValue?) throws {
        guard !isClosed else { throw ConnectionError.closed }
        outgoing.yield(try JSONEncoder.rpc.encode(Message.notification(method: method, params: params)))
    }

    /// Closes the transport and fails all pending requests with `ConnectionError.closed`.
    public func close() async {
        await transport.close()
        shutDown()
    }

    /// Waits until the connection is closed by either side.
    public func waitUntilClosed() async {
        guard !isClosed else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    // MARK: - Incoming

    private func receive(_ data: Data, handler: some MessageHandler) async {
        let message: Message
        do {
            message = try JSONDecoder.rpc.decode(Message.self, from: data)
        } catch {
            Log.connection.error("Malformed message: \(error, privacy: .public)")
            let isJSON = (try? JSONDecoder.rpc.decode(JSONValue.self, from: data)) != nil
            let id = (try? JSONDecoder.rpc.decode(JSONValue.self, from: data))?["id"]
                .flatMap { try? $0.decode(as: RequestID.self) }
            reply(id: id, .failure(isJSON ? .invalidRequest() : .parseError()))
            return
        }

        switch message {
        case .response(let id, let result):
            guard let id, let request = pending.removeValue(forKey: id) else {
                Log.connection.error("Response to unknown request \(String(describing: id), privacy: .public)")
                return
            }
            // Remove before awaiting: a consumer may close the connection on a persistence failure.
            switch result {
            case .success(let value): await request.succeed(value)
            case .failure(let error): request.fail(error)
            }

        case .notification(Self.cancelRequestMethod, let params):
            if let id = params?["requestId"].flatMap({ try? $0.decode(as: RequestID.self) }) {
                inFlight[id]?.cancel()
            }

        case .notification(let method, let params):
            await handler.handleNotification(method: method, params: params, rawMessage: data)

        case .request(let id, let method, let params):
            inFlight[id] = Task {
                let result: Result<JSONValue, RPCError>
                do {
                    result = .success(try await handler.handleRequest(method: method, params: params))
                } catch let error as RPCError {
                    result = .failure(error)
                } catch is CancellationError {
                    result = .failure(.requestCancelled())
                } catch {
                    result = .failure(.internalError(String(describing: error)))
                }
                self.finishIncoming(id, result)
            }
        }
    }

    private func finishIncoming(_ id: RequestID, _ result: Result<JSONValue, RPCError>) {
        inFlight[id] = nil
        reply(id: id, result)
    }

    private func reply(id: RequestID?, _ result: Result<JSONValue, RPCError>) {
        guard !isClosed, let data = try? JSONEncoder.rpc.encode(Message.response(id: id, result: result)) else {
            return
        }
        outgoing.yield(data)
    }

    // MARK: - Lifecycle

    private func cancelOutgoing(_ id: RequestID) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.fail(CancellationError())
        try? notify(method: Self.cancelRequestMethod, params: ["requestId": id.jsonValue])
    }

    private func shutDown() {
        guard !isClosed else { return }
        isClosed = true
        outgoing.finish()
        for request in pending.values {
            request.fail(ConnectionError.closed)
        }
        pending.removeAll()
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
        for waiter in closeWaiters {
            waiter.resume()
        }
        closeWaiters.removeAll()
    }

    static let cancelRequestMethod = "$/cancel_request"
}
