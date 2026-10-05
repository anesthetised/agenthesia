import JSONRPC
import Synchronization
import Testing

enum Add: RPCRequest {
    struct Params: Codable, Sendable {
        var a: Int
        var b: Int
    }
    typealias Result = Int
    static let method = "math/add"
}

enum Ping: RPCRequest {
    typealias Params = JSONRPC.Empty
    typealias Result = JSONRPC.Empty
    static let method = "ping"
}

enum Log: RPCNotification {
    struct Params: Codable, Sendable {
        var text: String
    }
    static let method = "log"
}

@Suite struct RouterTests {
    @Test func dispatchesTypedRequests() async throws {
        var router = Router()
        router.on(Add.self) { $0.a + $0.b }
        router.on(Ping.self) { _ in JSONRPC.Empty() }
        #expect(router.requestMethods == ["math/add", "ping"])
        #expect(try await router.handleRequest(method: "math/add", params: ["a": 2, "b": 3]) == 5)
        #expect(try await router.handleRequest(method: "ping", params: nil) == [:])
    }

    @Test func rejectsUnknownMethodsAndInvalidParams() async {
        var router = Router()
        router.on(Add.self) { $0.a + $0.b }
        await #expect(throws: RPCError.methodNotFound("nope")) {
            try await router.handleRequest(method: "nope", params: nil)
        }
        do {
            _ = try await router.handleRequest(method: "math/add", params: ["a": "x"])
            Issue.record("Expected invalid params")
        } catch let error as RPCError {
            #expect(error.code == RPCError.invalidParamsCode)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func dispatchesNotificationsAndDropsInvalidOnes() async {
        let received = Mutex<[String]>([])
        var router = Router()
        router.on(Log.self) { params in received.withLock { $0.append(params.text) } }
        #expect(router.notificationMethods == ["log"])
        await router.handleNotification(method: "log", params: ["text": "hi"])
        await router.handleNotification(method: "log", params: ["text": 1])
        await router.handleNotification(method: "unknown", params: nil)
        #expect(received.withLock { $0 } == ["hi"])
    }
}
