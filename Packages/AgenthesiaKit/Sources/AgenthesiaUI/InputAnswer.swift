import ACP
import AgenthesiaCore
import Foundation
import JSONRPC

/// An answered, declined or cancelled form as the transcript records it (#340), as T3 Code shows an answered
/// question: each of the composer's steps (`InputStep.steps`) with its question and its answer, read from the form's
/// schema and the stored response, never from an agent's field names.
struct InputAnswer: Equatable {
    struct Pair: Equatable {
        let question: String
        /// Empty when the step was left unanswered or the form was not submitted.
        let answer: String
    }

    let pairs: [Pair]
    /// What stands in for the answers of a form that was not submitted: `Declined`, `Cancelled`, `Recording answer…`.
    let outcome: String?

    /// `recording` tells that the response is being stored; without a response and not recording, the form was
    /// cancelled, as a saved session's unanswered form is.
    init(_ input: TranscriptState.Input, recording: Bool) {
        let request = input.request
        let schema: ACP.ElicitationSchema
        if case .form(let form) = request.mode { schema = form } else { schema = .init(properties: [:]) }
        var values: [String: JSONValue] = [:]
        switch input.response?.action {
        case .accept(let accepted): (values, outcome) = (accepted ?? [:], nil)
        case .decline: outcome = "Declined"
        case .cancel: outcome = "Cancelled"
        case nil: outcome = recording ? "Recording answer…" : "Cancelled"
        case .unknown: outcome = "Unknown outcome"
        }
        pairs = InputStep.steps(schema).map { step in
            Pair(
                question: Self.question(step, schema: schema) ?? request.message,
                answer: Self.answer(step, values: values, schema: schema)
            )
        }
    }

    /// The step's question: its first field's description, else its title, else its name.
    private static func question(_ step: InputStep, schema: ACP.ElicitationSchema) -> String? {
        guard let key = step.keys.first else { return nil }
        let metadata = schema.properties[key].map(InputField.metadata)
        return metadata?.description ?? metadata?.title ?? key
    }

    /// The text answer replaces the pick, as the adapter's custom field means; a multiple choice joins its picks.
    private static func answer(_ step: InputStep, values: [String: JSONValue], schema: ACP.ElicitationSchema) -> String
    {
        if let key = step.text, let text = values[key].map({ display($0, choices: []) }), !text.isEmpty { return text }
        guard let key = step.control, let value = values[key] else { return "" }
        return display(value, choices: InputStep.choices(schema.properties[key]))
    }

    /// A value as the user picked it: a choice by its title.
    static func display(_ value: JSONValue, choices: [ACP.EnumOption]) -> String {
        switch value {
        case .string(let text): choices.first { $0.const == text }?.title ?? text
        case .bool(let value): value ? "Yes" : "No"
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .array(let values):
            values.map { display($0, choices: choices) }.filter { !$0.isEmpty }.joined(separator: ", ")
        default: ""
        }
    }

    /// The row's heading: the questions on one line each, joined with ` · `.
    var questions: String {
        pairs.map { $0.question.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.joined(separator: " · ")
    }

    /// The answers after the heading, joined with ` · `, or the outcome of a form that was not submitted.
    var answers: String {
        outcome
            ?? pairs.map(\.answer).filter { !$0.isEmpty }.map {
                $0.split(whereSeparator: \.isNewline).joined(separator: " ")
            }
            .joined(separator: " · ")
    }

    /// What Copy returns: each question with its answer indented below, then the outcome.
    var text: String {
        let blocks = pairs.map { $0.answer.isEmpty ? $0.question : "\($0.question)\n  \($0.answer)" }
        return (blocks + [outcome].compactMap(\.self)).joined(separator: "\n\n")
    }
}
