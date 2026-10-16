import ACP
import AgenthesiaCore
import Foundation
import JSONRPC
import SwiftUI

struct InputForm: View {
    let card: InputCard

    var body: some View {
        if case .form(let schema) = card.input.request.mode {
            let errors = card.active ? InputValidation.errors(in: card.draft.values, schema: schema) : [:]
            VStack(alignment: .leading, spacing: 12) {
                if let title = schema.title { Text(title).font(.headline) }
                if let description = schema.description { Text(description).foregroundStyle(.secondary) }
                if card.active {
                    ForEach(schema.properties.keys.sorted(), id: \.self) { key in
                        if let field = schema.properties[key] {
                            InputField(key: key, field: field, schema: schema, draft: card.draft, error: errors[key])
                        }
                    }
                    ForEach((schema.required ?? []).filter { schema.properties[$0] == nil }, id: \.self) { key in
                        Text("Unsupported required field: \(key)").font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Submit") { card.answer(.init(action: .accept(card.draft.values))) }
                            .disabled(!errors.isEmpty)
                        Button("Decline") { card.answer(.init(action: .decline)) }
                        Button("Cancel") { card.answer(.init(action: .cancel)) }
                    }
                } else {
                    Text(card.recording ? "Recording answer…" : Self.outcome(card.input.response)).font(.subheadline)
                    if case .accept(let values) = card.input.response?.action {
                        ForEach((values ?? [:]).keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: Self.display(values?[key]))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Input request")
        }
    }

    static func outcome(_ response: ACP.ElicitationResponse?) -> String {
        switch response?.action {
        case .accept: "Submitted"
        case .decline: "Declined"
        case .cancel, nil: "Cancelled"
        case .unknown: "Unknown outcome"
        }
    }
    static func display(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text): text
        case .bool(let value): value ? "Yes" : "No"
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .array(let values): values.map { display($0) }.joined(separator: ", ")
        default: ""
        }
    }
}
