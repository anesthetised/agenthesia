import Foundation
import JSONRPC
import Testing

@Suite struct MessageTests {
    private func decode(_ json: String) throws -> Message {
        try JSONDecoder.rpc.decode(Message.self, from: Data(json.utf8))
    }

    private func roundTrip(_ message: Message) throws -> Message {
        try JSONDecoder.rpc.decode(Message.self, from: JSONEncoder.rpc.encode(message))
    }

    @Test func decodesRequests() throws {
        #expect(
            try decode(#"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":1}}"#)
                == .request(id: .int(1), method: "m", params: ["a": 1])
        )
        #expect(
            try decode(#"{"jsonrpc":"2.0","id":"x","method":"m"}"#)
                == .request(id: .string("x"), method: "m", params: nil)
        )
    }

    @Test func decodesNotifications() throws {
        #expect(try decode(#"{"jsonrpc":"2.0","method":"n"}"#) == .notification(method: "n", params: nil))
        #expect(
            try decode(#"{"jsonrpc":"2.0","method":"n","params":[1]}"#)
                == .notification(method: "n", params: [1])
        )
    }

    @Test func decodesResponses() throws {
        #expect(
            try decode(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#)
                == .response(id: .int(3), result: .success(["ok": true]))
        )
        #expect(
            try decode(#"{"jsonrpc":"2.0","id":3,"result":null}"#) == .response(id: .int(3), result: .success(nil))
        )
        #expect(
            try decode(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"no"}}"#)
                == .response(id: .int(3), result: .failure(RPCError(code: -32601, message: "no")))
        )
        #expect(
            try decode(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"bad","data":[1]}}"#)
                == .response(id: nil, result: .failure(RPCError(code: -32700, message: "bad", data: [1])))
        )
    }

    @Test func rejectsInvalidMessages() {
        #expect(throws: DecodingError.self) { try decode(#"{"jsonrpc":"1.0","id":1,"method":"m"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"jsonrpc":"2.0","id":1}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"id":1,"method":"m"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"jsonrpc":"2.0","result":1}"#) }
    }

    @Test(
        arguments: [
            Message.request(id: .int(1), method: "m", params: ["a": [1, 2]]),
            .request(id: .string("s"), method: "m", params: nil),
            .notification(method: "n", params: ["x": nil]),
            .notification(method: "n", params: nil),
            .response(id: .int(2), result: .success(["k": "v"])),
            .response(id: .int(2), result: .success(nil)),
            .response(id: .string("e"), result: .failure(.methodNotFound("m"))),
            .response(id: nil, result: .failure(.parseError())),
        ]
    )
    func roundTrips(message: Message) throws {
        #expect(try roundTrip(message) == message)
    }

    @Test func encodesNullIdForUnknownErrors() throws {
        let data = try JSONEncoder.rpc.encode(Message.response(id: nil, result: .failure(.parseError())))
        let object = try JSONDecoder.rpc.decode(JSONValue.self, from: data)
        #expect(object["id"] == .null)
        #expect(object["jsonrpc"] == "2.0")
    }
}

@Suite struct RequestIDTests {
    @Test func decodesIntegersAndStrings() throws {
        #expect(try JSONDecoder().decode(RequestID.self, from: Data("5".utf8)) == .int(5))
        #expect(try JSONDecoder().decode(RequestID.self, from: Data(#""a""#.utf8)) == .string("a"))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RequestID.self, from: Data("true".utf8)) }
    }

    @Test func describesAndConverts() {
        #expect(RequestID.int(5).description == "5")
        #expect(RequestID.string("a").description == "a")
        #expect(RequestID.int(5).jsonValue == 5)
        #expect(RequestID.string("a").jsonValue == "a")
    }
}

@Suite struct RPCErrorTests {
    @Test func factoriesUseStandardCodes() {
        #expect(RPCError.parseError().code == -32700)
        #expect(RPCError.invalidRequest().code == -32600)
        #expect(RPCError.methodNotFound("x").code == -32601)
        #expect(RPCError.methodNotFound("x").message.contains("x"))
        #expect(RPCError.invalidParams().code == -32602)
        #expect(RPCError.internalError().code == -32603)
        #expect(RPCError.requestCancelled().code == -32800)
        #expect(RPCError.authRequiredCode == -32000)
        #expect(RPCError.resourceNotFoundCode == -32002)
    }
}
