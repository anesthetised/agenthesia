import ACP
import AgenthesiaCore
import JSONRPC
import SwiftUI

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
            switch field {
            case .boolean:
                Toggle(
                    title,
                    isOn: Binding(
                        get: { draft.values[key] == .bool(true) },
                        set: { draft.values[key] = .bool($0) }
                    )
                )
            case .string(let string) where string.enum != nil || string.oneOf != nil:
                Picker(
                    title,
                    selection: Binding(
                        get: { draft.text[key] },
                        set: { value in
                            if let value {
                                draft.edit(key, text: value, field: field)
                            } else {
                                draft.text.removeValue(forKey: key); draft.values.removeValue(forKey: key)
                            }
                        }
                    )
                ) {
                    Text("Choose…").tag(Optional<String>.none)
                    ForEach(
                        string.oneOf ?? (string.enum ?? []).map { ACP.EnumOption(const: $0, title: $0) },
                        id: \.const
                    ) { option in
                        Text(option.title).tag(Optional(option.const))
                    }
                }
            case .multiSelect(let multiple):
                Text(title)
                if case .unknown = multiple.items { Text("Unsupported choices.").foregroundStyle(.secondary) }
                ForEach(Self.choices(multiple.items), id: \.const) { option in
                    Toggle(
                        option.title,
                        isOn: Binding(
                            get: {
                                if case .array(let values) = draft.values[key] {
                                    values.contains(.string(option.const))
                                } else {
                                    false
                                }
                            },
                            set: { selected in
                                var values: [JSONValue] = []
                                if case .array(let current) = draft.values[key] { values = current }
                                values.removeAll { $0 == .string(option.const) }
                                if selected { values.append(.string(option.const)) }
                                if values.isEmpty, schema.required?.contains(key) != true {
                                    draft.values.removeValue(forKey: key)
                                } else {
                                    draft.values[key] = .array(values)
                                }
                            }
                        )
                    )
                }
            case .unknown:
                Text("\(title): unsupported field").foregroundStyle(.secondary)
            default:
                TextField(
                    title,
                    text: Binding(
                        get: { draft.text[key] ?? "" },
                        set: { draft.edit(key, text: $0, field: field) }
                    )
                )
                .textFieldStyle(.roundedBorder)
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
