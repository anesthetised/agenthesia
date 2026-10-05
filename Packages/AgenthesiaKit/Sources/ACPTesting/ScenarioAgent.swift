import Foundation
public import JSONRPC

/// Plays a `Scenario` over a transport, from the agent's side, and reports where the client deviated.
public actor ScenarioAgent {
    /// A deviation from the scenario. Playback stops at the first one.
    public struct Mismatch: Error, Sendable, CustomStringConvertible {
        public var step: Int
        public var message: String

        public var description: String { "Step \(step): \(message)" }
    }

    private let scenario: Scenario
    private let transport: any MessageTransport
    private let timeout: Duration
    private var inbox: [Message] = []
    private var waiter: (id: Int, continuation: CheckedContinuation<Message?, Never>)?
    private var waiterID = 0
    private var isFinished = false
    private var deferred: [String: RequestID] = [:]
    private var nextID = 1

    public init(scenario: Scenario, transport: some MessageTransport, timeout: Duration = .seconds(5)) {
        self.scenario = scenario
        self.transport = transport
        self.timeout = timeout
    }

    /// Plays the scenario. Returns `nil` when the client followed it, otherwise the first deviation.
    public func run() async -> Mismatch? {
        let reader = Task { [transport] in
            do {
                for try await data in transport.messages {
                    receive(data)
                }
            } catch {}
            finish()
        }
        defer { reader.cancel() }

        for (index, step) in scenario.steps.enumerated() {
            if let message = await play(step) {
                return Mismatch(step: index, message: message)
            }
        }
        return nil
    }

    /// Plays one step and returns a description of the deviation, if any.
    private func play(_ step: Scenario.Step) async -> String? {
        switch step {
        case .expectRequest(let method, let params, let response, let deferAs):
            guard let message = await next() else { return "Expected request \(method), connection closed" }
            guard case .request(let id, method, let actual) = message else {
                return "Expected request \(method), got \(message)"
            }
            if let params, !(actual ?? .object([:])).contains(params) {
                return "Params of \(method) \(String(describing: actual)) do not contain \(params)"
            }
            if let deferAs {
                deferred[deferAs] = id
            } else if let response {
                await send(.response(id: id, result: Self.result(response)))
            }
            return nil

        case .expectNotification(let method, let params):
            guard let message = await next() else { return "Expected notification \(method), connection closed" }
            guard case .notification(method, let actual) = message else {
                return "Expected notification \(method), got \(message)"
            }
            if let params, !(actual ?? .object([:])).contains(params) {
                return "Params of \(method) \(String(describing: actual)) do not contain \(params)"
            }
            return nil

        case .respond(let label, let response):
            guard let id = deferred.removeValue(forKey: label) else { return "No deferred request \(label)" }
            await send(.response(id: id, result: Self.result(response)))
            return nil

        case .sendNotification(let method, let params):
            await send(.notification(method: method, params: params))
            return nil

        case .sendRequest(let method, let params, let expect):
            let id = RequestID.string("agent-\(nextID)")
            nextID += 1
            await send(.request(id: id, method: method, params: params))
            guard let message = await next() else { return "Expected response to \(method), connection closed" }
            guard case .response(id, let result) = message else {
                return "Expected response to \(method), got \(message)"
            }
            switch (expect, result) {
            case (nil, _):
                return nil
            case (.result(let expected), .success(let actual)) where actual.contains(expected):
                return nil
            case (.error(let expected), .failure(let actual)) where actual.code == expected.code:
                return nil
            default:
                return "Response to \(method) \(result) does not match \(String(describing: expect))"
            }

        case .delay(let milliseconds):
            try? await Task.sleep(for: .milliseconds(milliseconds))
            return nil
        }
    }

    private static func result(_ response: Scenario.Response) -> Result<JSONValue, RPCError> {
        switch response {
        case .result(let value): .success(value)
        case .error(let error): .failure(error)
        }
    }

    private func send(_ message: Message) async {
        guard let data = try? JSONEncoder.rpc.encode(message) else { return }
        try? await transport.send(data)
    }

    // MARK: - Inbox

    private func receive(_ data: Data) {
        guard let message = try? JSONDecoder.rpc.decode(Message.self, from: data) else { return }
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: message)
        } else {
            inbox.append(message)
        }
    }

    private func finish() {
        isFinished = true
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: nil)
        }
    }

    /// The next message from the client, or `nil` on timeout or when the connection closed.
    private func next() async -> Message? {
        if !inbox.isEmpty {
            return inbox.removeFirst()
        }
        guard !isFinished else { return nil }
        waiterID += 1
        let id = waiterID
        let timeout = timeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            expire(id)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { waiter = (id, $0) }
    }

    private func expire(_ id: Int) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }
}
