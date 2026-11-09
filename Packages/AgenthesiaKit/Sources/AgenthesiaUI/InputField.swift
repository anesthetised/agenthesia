import ACP
import AgenthesiaCore
import JSONRPC
import SwiftUI

/// A form field that offers no choices and that the composer's text cannot answer: a toggle, or a note that the
/// field is unsupported (#326).
struct InputField: View {
    let key: String
    let field: ACP.PropertySchema
    let schema: ACP.ElicitationSchema
    let draft: InputDraft
    let error: String?

    var body: some View {
        let metadata = Self.metadata(field)
        let title = (metadata.title ?? key) + (schema.required?.contains(key) == true ? " (required)" : "")
        VStack(alignment: .leading, spacing: 4) {
            if case .boolean = field {
                Toggle(
                    title,
                    isOn: Binding(
                        get: { draft.values[key] == .bool(true) },
                        set: { draft.values[key] = .bool($0) }
                    )
                )
            } else {
                Text("\(title): unsupported field").foregroundStyle(.secondary)
            }
            if let description = metadata.description { Text(description).font(.caption).foregroundStyle(.secondary) }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    static func metadata(_ field: ACP.PropertySchema) -> (title: String?, description: String?) {
        switch field {
        case .string(let s): (s.title, s.description)
        case .number(let s): (s.title, s.description)
        case .integer(let s): (s.title, s.description)
        case .boolean(let s): (s.title, s.description)
        case .multiSelect(let s): (s.title, s.description)
        case .unknown: (nil, nil)
        }
    }
    static func choices(_ items: ACP.MultiSelectItems) -> [ACP.EnumOption] {
        switch items {
        case .strings(let choices): choices.map { .init(const: $0, title: $0) }
        case .titled(let choices): choices
        case .unknown: []
        }
    }
}
