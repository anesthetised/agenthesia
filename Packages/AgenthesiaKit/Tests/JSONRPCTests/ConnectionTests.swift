import Foundation
import JSONRPC
import Synchronization
import Testing

/// The raw side of an in-memory transport, driven by a test.
actor Peer {
    let transport: InMemoryTransport
    private var iterator: AsyncThrowingStream<Data, any Error>.Iterator

    init(_ transport: InMemoryTransport) {
        self.transport = transport
        iterator = transport.messages.makeAsyncIterator()
    }

    func next() async throws -> Message? {
        var iterator = self.iterator
        defer { self.iterator = iterator }
        guard let data = try await iterator.next(isolation: self) else { return nil }
        return try JSONDecoder.rpc.decode(Message.self, from: data)
    }

    func send(_ message: Message) async throws {
        try await transport.send(JSONEncoder.rpc.encode(message))
    }

    func sendRaw(_ text: String) async throws {
        try await transport.send(Data(text.utf8))
    }
}

/// Records events from concurrently running handlers.
final class Recorder: Sendable {
    private let events = Mutex<[String]>([])

    func record(_ event: String) {
        events.withLock { $0.append(event) }
    }

    var all: [String] { events.withLock { $0 } }
}

private func makeConnection(
    router: Router = Router(),
    traffic: Connection.TrafficObserver? = nil
) async -> (Connection, Peer) {
    let (local, remote) = InMemoryTransport.pair()
    let connection = Connection(transport: local, traffic: traffic)
    await connection.start(handler: router)
    return (connection, Peer(remote))
}

@Suite(.timeLimit(.minutes(1))) struct ConnectionTests {
    @Test func sendsTypedRequestsAndDecodesResults() async throws {
        let (connection, peer) = await makeConnection()
        async let sum = connection.request(Add.self, .init(a: 2, b: 3))
        let request = try #require(try await peer.next())
        guard case .request(let id, "math/add", let params) = request else {
            Issue.record("Unexpected \(request)")
            return
        }
        #expect(params == ["a": 2, "b": 3])
        try await peer.send(.response(id: id, result: .success(5)))
        #expect(try await sum == 5)
    }

    @Test func correlatesResponsesArrivingOutOfOrder() async throws {
        let (connection, peer) = await makeConnection()
        async let first = connection.request(method: "a", params: nil)
        async let second = connection.request(method: "b", params: nil)
        var ids: [String: RequestID] = [:]
        for _ in 0..<2 {
            if case .request(let id, let method, _) = try await peer.next() {
                ids[method] = id
            }
        }
        #expect(Set(ids.values).count == 2)
        try await peer.send(.response(id: ids["b"], result: .success("B")))
        try await peer.send(.response(id: ids["a"], result: .success("A")))
        #expect(try await first == "A")
        #expect(try await second == "B")
    }

    @Test func throwsErrorResponses() async throws {
        let (connection, peer) = await makeConnection()
        let result = Task { try await connection.request(method: "m", params: nil) }
        guard case .request(let id, _, _) = try await peer.next() else { return }
        try await peer.send(.response(id: id, result: .failure(RPCError(code: -32000, message: "auth"))))
        await #expect(throws: RPCError(code: -32000, message: "auth")) { try await result.value }
    }

    @Test func throwsOnUnexpectedResultType() async throws {
        let (connection, peer) = await makeConnection()
        async let sum = connection.request(Add.self, .init(a: 1, b: 1))
        guard case .request(let id, _, _) = try await peer.next() else { return }
        try await peer.send(.response(id: id, result: .success("two")))
        do {
            _ = try await sum
            Issue.record("Expected invalid result")
        } catch let error as ConnectionError {
            guard case .invalidResult(method: "math/add", _) = error else {
                Issue.record("Unexpected \(error)")
                return
            }
        }
    }

    @Test func cancellingSendsCancelRequestAndIgnoresLateResponse() async throws {
        let (connection, peer) = await makeConnection()
        let task = Task { try await connection.request(method: "slow", params: nil) }
        guard case .request(let id, "slow", _) = try await peer.next() else { return }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await peer.next() == .notification(method: "$/cancel_request", params: ["requestId": id.jsonValue]))
        try await peer.send(.response(id: id, result: .success("late")))
        // The connection is still usable afterwards.
        async let next = connection.request(method: "after", params: nil)
        guard case .request(let nextID, "after", _) = try await peer.next() else { return }
        try await peer.send(.response(id: nextID, result: .success(1)))
        #expect(try await next == 1)
    }

    @Test func alreadyCancelledTaskDoesNotSend() async throws {
        let (connection, peer) = await makeConnection()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await connection.request(method: "never", params: nil)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        try await connection.notify(method: "marker", params: nil)
        #expect(try await peer.next() == .notification(method: "marker", params: nil))
    }

    @Test func answersIncomingRequests() async throws {
        var router = Router()
        router.on(Add.self) { $0.a + $0.b }
        router.on(Ping.self) { _ in throw RPCError(code: 7, message: "custom") }
        let (_, peer) = await makeConnection(router: router)

        try await peer.send(.request(id: .int(1), method: "math/add", params: ["a": 1, "b": 2]))
        #expect(try await peer.next() == .response(id: .int(1), result: .success(3)))

        try await peer.send(.request(id: .string("x"), method: "ping", params: nil))
        #expect(
            try await peer.next() == .response(id: .string("x"), result: .failure(RPCError(code: 7, message: "custom")))
        )

        try await peer.send(.request(id: .int(2), method: "unknown", params: nil))
        #expect(try await peer.next() == .response(id: .int(2), result: .failure(.methodNotFound("unknown"))))
    }

    @Test func mapsUnexpectedHandlerErrorsToInternalError() async throws {
        struct Boom: Error {}
        var router = Router()
        router.on(Ping.self) { _ in throw Boom() }
        let (_, peer) = await makeConnection(router: router)
        try await peer.send(.request(id: .int(1), method: "ping", params: nil))
        guard case .response(.int(1), .failure(let error)) = try await peer.next() else {
            Issue.record("Expected an error response")
            return
        }
        #expect(error.code == RPCError.internalErrorCode)
    }

    @Test func incomingCancelRequestCancelsHandler() async throws {
        let started = Recorder()
        var router = Router()
        router.on(Ping.self) { _ in
            started.record("started")
            try await Task.sleep(for: .seconds(30))
            return JSONRPC.Empty()
        }
        let (_, peer) = await makeConnection(router: router)
        try await peer.send(.request(id: .int(9), method: "ping", params: nil))
        while started.all.isEmpty {
            await Task.yield()
        }
        try await peer.send(.notification(method: "$/cancel_request", params: ["requestId": 9]))
        #expect(try await peer.next() == .response(id: .int(9), result: .failure(.requestCancelled())))
    }

    @Test func notificationsAreHandledBeforeLaterRequests() async throws {
        let recorder = Recorder()
        var router = Router()
        router.on(Log.self) { params in
            try? await Task.sleep(for: .milliseconds(50))
            recorder.record("notification \(params.text)")
        }
        router.on(Ping.self) { _ in
            recorder.record("request")
            return JSONRPC.Empty()
        }
        let (_, peer) = await makeConnection(router: router)
        try await peer.send(.notification(method: "log", params: ["text": "1"]))
        try await peer.send(.notification(method: "log", params: ["text": "2"]))
        try await peer.send(.request(id: .int(1), method: "ping", params: nil))
        _ = try await peer.next()
        #expect(recorder.all == ["notification 1", "notification 2", "request"])
    }

    @Test func answersMalformedMessages() async throws {
        let (_, peer) = await makeConnection()
        try await peer.sendRaw("{not json")
        #expect(try await peer.next() == .response(id: nil, result: .failure(.parseError())))
        try await peer.sendRaw(#"{"jsonrpc":"2.0","id":4}"#)
        #expect(try await peer.next() == .response(id: .int(4), result: .failure(.invalidRequest())))
        try await peer.sendRaw(#"[1,2]"#)
        #expect(try await peer.next() == .response(id: nil, result: .failure(.invalidRequest())))
    }

    @Test func ignoresResponsesToUnknownRequests() async throws {
        let (connection, peer) = await makeConnection()
        try await peer.send(.response(id: .int(99), result: .success(nil)))
        try await peer.send(.response(id: nil, result: .failure(.parseError())))
        async let result = connection.request(method: "m", params: nil)
        guard case .request(let id, _, _) = try await peer.next() else { return }
        try await peer.send(.response(id: id, result: .success(true)))
        #expect(try await result == true)
    }

    @Test func peerClosingFailsPendingRequests() async throws {
        let (connection, peer) = await makeConnection()
        let result = Task { try await connection.request(method: "m", params: nil) }
        _ = try await peer.next()
        await peer.transport.close()
        await #expect(throws: ConnectionError.closed) { try await result.value }
        await connection.waitUntilClosed()
        await #expect(throws: ConnectionError.closed) { try await connection.request(method: "m", params: nil) }
        await #expect(throws: ConnectionError.closed) { try await connection.notify(method: "n", params: nil) }
    }

    @Test func closeFailsPendingRequests() async throws {
        let (connection, peer) = await makeConnection()
        let task = Task { try await connection.request(method: "m", params: nil) }
        _ = try await peer.next()
        await connection.close()
        await #expect(throws: ConnectionError.closed) { try await task.value }
        await connection.waitUntilClosed()
    }

    @Test func sendsTypedNotifications() async throws {
        let (connection, peer) = await makeConnection()
        try await connection.notify(Log.self, .init(text: "hi"))
        #expect(try await peer.next() == .notification(method: "log", params: ["text": "hi"]))
    }

    @Test func reportsTraffic() async throws {
        let recorder = Recorder()
        let (connection, peer) = await makeConnection { direction, data in
            recorder.record("\(direction) \(String(decoding: data, as: UTF8.self))")
        }
        try await connection.notify(method: "out", params: nil)
        _ = try await peer.next()
        try await peer.send(.notification(method: "in", params: nil))
        try await connection.notify(method: "barrier", params: nil)
        _ = try await peer.next()
        let events = recorder.all
        #expect(events.contains { $0.hasPrefix("outgoing") && $0.contains(#""out""#) })
        #expect(events.contains { $0.hasPrefix("incoming") && $0.contains(#""in""#) })
    }
}
