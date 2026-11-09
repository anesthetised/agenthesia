import ACP
import AgenthesiaCore
import Foundation
import JSONRPC
import SwiftUI

/// A form's record in the transcript once it is answered or cancelled; a waiting form docks in the composer (#326).
struct InputForm: View {
    let card: InputCard

    var body: some View {
        if case .form(let schema) = card.input.request.mode {
            VStack(alignment: .leading, spacing: 12) {
                if let title = schema.title { Text(title).font(.headline) }
                if let description = schema.description { Text(description).foregroundStyle(.secondary) }
                Text(card.recording ? "Recording answer…" : Self.outcome(card.input.response)).font(.subheadline)
                if case .accept(let values) = card.input.response?.action {
                    ForEach((values ?? [:]).keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: Self.display(values?[key]))
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
