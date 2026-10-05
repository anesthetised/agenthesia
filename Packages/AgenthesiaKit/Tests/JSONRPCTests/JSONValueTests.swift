import Foundation
import JSONRPC
import Testing

@Suite struct JSONValueTests {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func decodesEveryKind() throws {
        let value = try decode(
            #"{"n":null,"b":true,"i":42,"d":1.5,"s":"x","a":[1,"y"],"o":{"k":false}}"#
        )
        #expect(
            value == [
                "n": nil, "b": true, "i": 42, "d": 1.5, "s": "x", "a": [1, "y"], "o": ["k": false],
            ]
        )
    }

    @Test func keepsIntegersAndDoublesApart() throws {
        #expect(try decode("7") == .int(7))
        #expect(try decode("7.25") == .double(7.25))
        #expect(try decode("-9007199254740993") == .int(-9_007_199_254_740_993))
        #expect(try decode("true") == .bool(true))
        #expect(try decode("1") != .bool(true))
    }

    @Test func numbersCompareByValue() {
        #expect(JSONValue.int(1) == .double(1.0))
        #expect(JSONValue.double(2.0) == .int(2))
        #expect(JSONValue.int(1) != .double(1.5))
        #expect(Set<JSONValue>([.int(1), .double(1.0), .string("1")]).count == 2)
        #expect(JSONValue.null != .bool(false))
    }

    @Test func roundTrips() throws {
        let value: JSONValue = ["a": [1, 2.5, "three", nil, false], "b": ["c": ["d": "e"]]]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func convertsFromAndToCodable() throws {
        struct Point: Codable, Equatable {
            var x: Int
            var label: String?
        }
        let value = try JSONValue(encoding: Point(x: 3, label: "p"))
        #expect(value == ["x": 3, "label": "p"])
        #expect(try value.decode(as: Point.self) == Point(x: 3, label: "p"))
        #expect(throws: DecodingError.self) { try JSONValue.string("nope").decode(as: Point.self) }
    }

    @Test func accessors() {
        let value: JSONValue = ["s": "x", "i": 1, "b": true, "a": [1], "n": nil]
        #expect(value["s"]?.stringValue == "x")
        #expect(value["i"]?.intValue == 1)
        #expect(value["b"]?.boolValue == true)
        #expect(value["a"]?.arrayValue == [1])
        #expect(value["n"]?.isNull == true)
        #expect(value["missing"] == nil)
        #expect(value.objectValue?.count == 5)
        #expect(JSONValue.int(1)["key"] == nil)
        #expect(JSONValue.int(1).stringValue == nil)
        #expect(JSONValue.string("x").intValue == nil)
        #expect(JSONValue.string("x").boolValue == nil)
        #expect(JSONValue.string("x").arrayValue == nil)
        #expect(!JSONValue.string("x").isNull)
    }

    @Test func dictionaryLiteralKeepsLastDuplicate() {
        let value: JSONValue = ["k": 1, "k": 2]
        #expect(value == ["k": 2])
    }

    @Test func encoderOutputHasNoNewlines() throws {
        let value: JSONValue = ["text": "line one\nline two", "path": "/a/b"]
        let data = try JSONEncoder.rpc.encode(value)
        #expect(!data.contains(0x0A))
        #expect(String(decoding: data, as: UTF8.self).contains("/a/b"))
    }
}
