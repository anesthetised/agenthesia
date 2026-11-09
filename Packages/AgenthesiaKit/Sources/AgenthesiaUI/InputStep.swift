import ACP
import Foundation

/// One question of a form as the composer asks it (#326): a choice field with the optional string field after it,
/// whose text joins or replaces the pick, or any other field alone. Decided from the schema alone, never from an
/// agent's field names (VISION principle 8).
struct InputStep: Equatable {
    /// The field shown in the dock: a choice, or a field the composer's text cannot answer, such as a toggle.
    var control: String?
    /// The field the composer's text answers.
    var text: String?

    var keys: [String] { [control, text].compactMap(\.self) }

    /// The form's fields as steps, in the order of their names with numbers compared by value (`q_2` before `q_10`),
    /// since the decoded schema keeps no order. A form without fields is one empty step.
    static func steps(_ schema: ACP.ElicitationSchema) -> [InputStep] {
        let keys = schema.properties.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let required = Set(schema.required ?? [])
        var steps: [InputStep] = []
        var index = keys.startIndex
        while index < keys.endIndex {
            let key = keys[index]
            let field = schema.properties[key]
            index += 1
            if isChoice(field) {
                if index < keys.endIndex, case .string(let next) = schema.properties[keys[index]],
                    next.enum == nil, next.oneOf == nil, !required.contains(keys[index])
                {
                    steps.append(InputStep(control: key, text: keys[index]))
                    index += 1
                } else {
                    steps.append(InputStep(control: key))
                }
            } else if isText(field) {
                steps.append(InputStep(text: key))
            } else {
                steps.append(InputStep(control: key))
            }
        }
        return steps.isEmpty ? [InputStep()] : steps
    }

    /// The choices of a single or multiple choice field; empty for any other field.
    static func choices(_ field: ACP.PropertySchema?) -> [ACP.EnumOption] {
        switch field {
        case .string(let string): string.oneOf ?? (string.enum ?? []).map { .init(const: $0, title: $0) }
        case .multiSelect(let multiple): InputField.choices(multiple.items)
        default: []
        }
    }

    static func isChoice(_ field: ACP.PropertySchema?) -> Bool { !choices(field).isEmpty }

    /// A field typed as text: a plain string or a number.
    static func isText(_ field: ACP.PropertySchema?) -> Bool {
        switch field {
        case .string(let string): string.enum == nil && string.oneOf == nil
        case .number, .integer: true
        default: false
        }
    }
}
