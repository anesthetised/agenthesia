import ACP
import Foundation
import JSONRPC
import Observation

/// Temporary edits survive table virtualization, but are never written to the event log.
@MainActor @Observable final class InputDraft {
    var text: [String: String] = [:]
    var values: [String: JSONValue] = [:]

    init(schema: ACP.ElicitationSchema) {
        for (key, field) in schema.properties {
            switch field {
            case .string(let s): if let value = s.default { text[key] = value; values[key] = .string(value) }
            case .number(let s): if let value = s.default { text[key] = String(value); values[key] = .double(value) }
            case .integer(let s): if let value = s.default { text[key] = String(value); values[key] = .int(value) }
            case .boolean(let s): values[key] = .bool(s.default ?? false)
            case .multiSelect(let s):
                if case .unknown = s.items { break }
                if let defaults = s.default {
                    values[key] = .array(defaults.map(JSONValue.string))
                } else if schema.required?.contains(key) == true {
                    values[key] = .array([])
                }
            case .unknown: break
            }
        }
    }

    func edit(_ key: String, text: String, field: ACP.PropertySchema) {
        self.text[key] = text
        if case .string = field { values[key] = .string(text); return }
        guard !text.isEmpty else { values.removeValue(forKey: key); return }
        switch field {
        case .number: values[key] = Double(text).map(JSONValue.double) ?? .string(text)
        case .integer: values[key] = Int64(text).map(JSONValue.int) ?? .string(text)
        default: values[key] = .string(text)
        }
    }
}
