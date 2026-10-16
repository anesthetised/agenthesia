import ACP
import JSONRPC
import Testing

@testable import AgenthesiaCore

struct InputValidationTests {
    @Test func rejectsInvalidAndExpensivePatterns() {
        for pattern in ["[", "^(a+)+$"] {
            let schema = ACP.ElicitationSchema(properties: ["value": .string(.init(pattern: pattern))])
            #expect(
                !InputValidation.errors(
                    in: ["value": .string(String(repeating: "a", count: 10000) + "!")],
                    schema: schema
                ).isEmpty
            )
        }
    }

    @Test func validatesRequiredAndUnsupportedFields() {
        let schema = ACP.ElicitationSchema(
            properties: ["name": .string(.init(minLength: 2)), "future": .unknown(.null)],
            required: ["name", "future"]
        )
        #expect(!InputValidation.errors(in: [:], schema: schema).isEmpty)
        #expect(InputValidation.errors(in: ["name": "ok"], schema: schema)["future"] != nil)
    }
    @Test func validatesAllModeledConstraints() {
        let schema = ACP.ElicitationSchema(properties: [
            "email": .string(.init(format: .email)),
            "choice": .string(.init(oneOf: [.init(const: "a", title: "A")])),
            "number": .number(.init(minimum: 1, maximum: 3)),
            "integer": .integer(.init(minimum: 0, maximum: 10)),
            "boolean": .boolean(.init()),
            "many": .multiSelect(.init(minItems: 1, maxItems: 2, items: .strings(["a", "b"]))),
        ])
        let valid: [String: JSONValue] = [
            "email": "a@example.com", "choice": "a", "number": 2, "integer": 3, "boolean": false, "many": ["a"],
        ]
        #expect(InputValidation.errors(in: valid, schema: schema).isEmpty)
        #expect(InputValidation.errors(in: ["integer": .double(3)], schema: schema).isEmpty)
        let invalid: [String: JSONValue] = [
            "email": "x", "choice": "z", "number": 4, "integer": .double(1.5), "boolean": "false", "many": ["a", "a"],
        ]
        #expect(InputValidation.errors(in: invalid, schema: schema).count == 6)
    }
    @Test func validatesFormatsPatternAndUnknownValues() {
        let schema = ACP.ElicitationSchema(properties: [
            "date": .string(.init(format: .date)), "time": .string(.init(format: .dateTime)),
            "uri": .string(.init(format: .uri)),
            "code": .string(.init(minLength: 2, maxLength: 4, pattern: "^[A-Z]+$")),
        ])
        #expect(
            InputValidation.errors(
                in: [
                    "date": "2026-10-16", "time": "2026-10-16T12:00:00Z", "uri": "https://example.com", "code": "ABC",
                ],
                schema: schema
            ).isEmpty
        )
        #expect(
            InputValidation.errors(
                in: ["date": "2026-02-30", "time": "today", "uri": "relative", "code": "abcde"],
                schema: schema
            ).count == 4
        )
        #expect(!InputValidation.errors(in: ["unexpected": true], schema: schema).isEmpty)
    }
}

extension InputValidationTests {
    @Test func optionalFieldsAndConstraintEdges() {
        let schema = ACP.ElicitationSchema(properties: [
            "text": .string(.init(minLength: 2, maxLength: 3, enum: ["ab", "abc"])),
            "n": .number(.init(minimum: 1, maximum: 2)),
            "i": .integer(.init(minimum: 1, maximum: 2)),
            "b": .boolean(.init()),
            "m": .multiSelect(.init(minItems: 1, maxItems: 1, items: .titled([.init(const: "a", title: "A")]))),
            "future": .unknown(.null),
        ])
        #expect(InputValidation.errors(in: [:], schema: schema).isEmpty)
        let invalid: [[String: JSONValue]] = [
            ["text": "a"], ["text": "abcd"], ["text": "zz"], ["text": false],
            ["n": .double(.infinity)], ["n": 0], ["n": "1"], ["i": 0], ["i": 3], ["i": "1"], ["i": .double(.infinity)],
            ["m": []], ["m": ["a", "b"]], ["m": [true]], ["future": true],
        ]
        for values in invalid { #expect(!InputValidation.errors(in: values, schema: schema).isEmpty) }
        #expect(
            InputValidation.errors(
                in: ["text": "ab", "n": .double(1.5), "i": 2, "b": false, "m": ["a"]],
                schema: schema
            ).isEmpty
        )
        let unsupported = ACP.ElicitationSchema(properties: [
            "format": .string(.init(format: .unknown("new"))), "items": .multiSelect(.init(items: .unknown(.null))),
        ])
        #expect(InputValidation.errors(in: ["format": "x", "items": []], schema: unsupported).count == 2)
    }
}

extension InputValidationTests {
    @Test func stringLengthCountsUnicodeScalarsAndDateTimesAllowFractions() {
        let schema = ACP.ElicitationSchema(properties: [
            "text": .string(.init(minLength: 2, maxLength: 2)), "time": .string(.init(format: .dateTime)),
        ])
        #expect(
            InputValidation.errors(in: ["text": "e\u{301}", "time": "2026-10-16T12:00:00.123Z"], schema: schema).isEmpty
        )
        #expect(!InputValidation.errors(in: ["text": "é"], schema: schema).isEmpty)
    }
}
