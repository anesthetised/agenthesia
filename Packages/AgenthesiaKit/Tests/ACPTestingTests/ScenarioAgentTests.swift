import ACPTesting
import Foundation
import JSONRPC
import Synchronization
import Testing

/// Starts a scenario agent on one end of an in-memory pair and a client `Connection` on the other.
private func play(
    _ scenario: Scenario,
    router: Router = Router(),
    timeout: Duration = .seconds(5)
) async -> (Connection, Task<ScenarioAgent.Mismatch?, Never>) {
    let (agentSide, clientSide) = InMemoryTransport.pair()
    let agent = ScenarioAgent(scenario: scenario, transport: agentSide, timeout: timeout)
    let run = Task { await agent.run() }
    let client = Connection(transport: clientSide)
    await client.start(handler: router)
    return (client, run)
}

@Suite(.timeLimit(.minutes(1))) struct ScenarioAgentTests {
    @Test func followsAScenario() async throws {
        enum Read: RPCRequest {
            typealias Params = JSONValue
            typealias Result = JSONValue
            static let method = "fs/read_text_file"
        }
        var router = Router()
        router.on(Read.self) { params in ["content": .string("contents of \(params["path"]?.stringValue ?? "")")] }
        let updates = Recorder()
        enum Update: RPCNotification {
            typealias Params = JSONValue
            static let method = "session/update"
        }
        router.on(Update.self) { updates.record($0["n"]?.intValue.map(String.init) ?? "?") }

        let (client, run) = await play(
            Scenario([
                .expectRequest(
                    method: "initialize",
                    params: ["protocolVersion": 1],
                    response: .result(["protocolVersion": 1])
                ),
                .expectRequest(method: "session/prompt", response: nil, deferAs: "prompt"),
                .sendNotification(method: "session/update", params: ["n": 1]),
                .sendRequest(
                    method: "fs/read_text_file",
                    params: ["path": "/a"],
                    expect: .result(["content": "contents of /a"])
                ),
                .delay(milliseconds: 1),
                .sendNotification(method: "session/update", params: ["n": 2]),
                .respond(to: "prompt", response: .result(["stopReason": "end_turn"])),
                .expectNotification(method: "session/cancel", params: ["sessionId": "s"]),
            ]),
            router: router
        )
        #expect(
            try await client.request(method: "initialize", params: ["protocolVersion": 1, "extra": true]) == [
                "protocolVersion": 1
            ]
        )
        #expect(try await client.request(method: "session/prompt", params: nil) == ["stopReason": "end_turn"])
        try await client.notify(method: "session/cancel", params: ["sessionId": "s"])
        #expect(await run.value == nil)
        #expect(updates.all == ["1", "2"])
    }

    @Test func repliesWithErrors() async throws {
        let (client, run) = await play(
            Scenario([.expectRequest(method: "session/new", response: .error(RPCError(code: -32000, message: "auth")))])
        )
        await #expect(throws: RPCError(code: -32000, message: "auth")) {
            try await client.request(method: "session/new", params: nil)
        }
        #expect(await run.value == nil)
    }

    @Test func reportsUnexpectedMethodsAndClosesTheConnection() async throws {
        let (client, run) = await play(Scenario([.expectRequest(method: "initialize", response: .result(nil))]))
        let pending = Task { try await client.request(method: "session/new", params: nil) }
        let mismatch = await run.value
        #expect(mismatch?.step == 0)
        #expect(mismatch?.description.contains("initialize") == true)
        await #expect(throws: ConnectionError.closed) { try await pending.value }
    }

    @Test func reportsParamsThatDoNotMatch() async throws {
        let (client, run) = await play(
            Scenario([.expectNotification(method: "session/cancel", params: ["sessionId": "expected"])])
        )
        try await client.notify(method: "session/cancel", params: ["sessionId": "other"])
        #expect(await run.value?.step == 0)
    }

    @Test func reportsMismatchedResponses() async throws {
        enum Ask: RPCRequest {
            typealias Params = JSONValue
            typealias Result = JSONValue
            static let method = "ask"
        }
        var router = Router()
        router.on(Ask.self) { _ in ["answer": "no"] }
        let (_, run) = await play(
            Scenario([.sendRequest(method: "ask", params: nil, expect: .result(["answer": "yes"]))]),
            router: router
        )
        #expect(await run.value?.step == 0)
    }

    @Test func matchesErrorResponsesByCode() async throws {
        let (_, run) = await play(
            Scenario([.sendRequest(method: "unknown/method", params: nil, expect: .error(.methodNotFound("x")))])
        )
        #expect(await run.value == nil)
    }

    @Test func timesOutWhenTheClientIsSilent() async {
        let (_, run) = await play(
            Scenario([.expectRequest(method: "initialize", response: .result(nil))]),
            timeout: .milliseconds(50)
        )
        #expect(await run.value?.message.contains("closed") == true)
    }

    @Test func reportsClosedConnectionsAndUnknownDeferredRequests() async {
        let (client, run) = await play(Scenario([.respond(to: "nothing", response: .result(nil))]))
        #expect(await run.value?.message.contains("nothing") == true)
        await client.close()
    }

    @Test func detectsCloseWhileWaiting() async {
        let (client, run) = await play(Scenario([.expectNotification(method: "x")]))
        await client.close()
        #expect(await run.value?.step == 0)
    }
}

@Suite struct ScenarioCodingTests {
    @Test func decodesJSONScenarios() throws {
        let json = """
            {"steps": [
              {"step": "expectRequest", "method": "initialize", "params": {"protocolVersion": 1}, "result": {"protocolVersion": 1}},
              {"step": "expectRequest", "method": "session/new", "error": {"code": -32000, "message": "auth"}},
              {"step": "expectRequest", "method": "session/prompt", "deferAs": "p"},
              {"step": "expectNotification", "method": "session/cancel"},
              {"step": "sendNotification", "method": "session/update", "params": {"a": 1}},
              {"step": "sendRequest", "method": "fs/read_text_file", "params": {}, "result": {"content": ""}},
              {"step": "respond", "to": "p", "result": {"stopReason": "cancelled"}},
              {"step": "delay", "milliseconds": 5}
            ]}
            """
        let scenario = try JSONDecoder().decode(Scenario.self, from: Data(json.utf8))
        #expect(scenario.steps.count == 8)
        #expect(
            scenario.steps[1]
                == .expectRequest(method: "session/new", response: .error(RPCError(code: -32000, message: "auth")))
        )
        let reencoded = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scenario))
        #expect(reencoded.steps == scenario.steps)
    }

    @Test func rejectsInvalidSteps() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Scenario.self, from: Data(#"{"steps":[{"step":"dance"}]}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Scenario.self, from: Data(#"{"steps":[{"step":"respond","to":"p"}]}"#.utf8))
        }
    }
}

@Suite struct JSONMatchingTests {
    @Test func objectsMayHaveExtraMembers() {
        let value: JSONValue = ["a": 1, "b": ["c": 2, "d": 3], "e": [1, ["f": 4, "g": 5]]]
        #expect(value.contains(["a": 1]))
        #expect(value.contains(["b": ["c": 2]]))
        #expect(value.contains(["e": [1, ["f": 4]]]))
        #expect(!value.contains(["e": [1]]))
        #expect(!value.contains(["a": 2]))
        #expect(!value.contains(["missing": nil]))
        #expect(JSONValue.string("x").contains("x"))
        #expect(!JSONValue.string("x").contains(["x": 1]))
    }
}

final class Recorder: Sendable {
    private let events = Mutex<[String]>([])

    func record(_ event: String) {
        events.withLock { $0.append(event) }
    }

    var all: [String] { events.withLock { $0 } }
}
