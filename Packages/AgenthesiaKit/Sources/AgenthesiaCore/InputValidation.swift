public import ACP
import Foundation
public import JSONRPC

/// Validates the modeled ACP form schema at both the UI and response boundary.
public enum InputValidation {
    public static func errors(in values: [String: JSONValue], schema: ACP.ElicitationSchema) -> [String: String] {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(20))
        var errors: [String: String] = [:]
        for key in schema.required ?? [] where values[key] == nil {
            errors[key] = "Required field."
        }
        for (key, value) in values {
            guard let field = schema.properties[key] else { errors[key] = "Unknown field."; continue }
            if !valid(value, for: field, deadline: deadline) {
                errors[key] = "Enter a valid value within the field's constraints."
            }
        }
        for (key, field) in schema.properties {
            if case .unknown = field, schema.required?.contains(key) == true {
                errors[key] = "This required field is unsupported. Decline or cancel this request."
            }
        }
        return errors
    }

    /// Agent-provided expressions must not monopolize the main thread while a user types.
    private static func matches(_ pattern: String, text: String, deadline: ContinuousClock.Instant) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        guard ContinuousClock.now < deadline else { return false }
        var matched = false
        regex.enumerateMatches(in: text, options: .reportProgress, range: NSRange(text.startIndex..., in: text)) {
            result,
            _,
            stop in
            if ContinuousClock.now >= deadline { stop.pointee = true; return }
            if result != nil { matched = true; stop.pointee = true }
        }
        return matched
    }

    private static func valid(
        _ value: JSONValue,
        for field: ACP.PropertySchema,
        deadline: ContinuousClock.Instant
    ) -> Bool {
        switch (field, value) {
        case (.string(let schema), .string(let text)):
            if let min = schema.minLength, text.unicodeScalars.count < min { return false }
            if let max = schema.maxLength, text.unicodeScalars.count > max { return false }
            if let pattern = schema.pattern {
                guard matches(pattern, text: text, deadline: deadline) else { return false }
            }
            if let choices = schema.enum, !choices.contains(text) { return false }
            if let choices = schema.oneOf, !choices.contains(where: { $0.const == text }) { return false }
            switch schema.format {
            case .email: return text.range(of: "^[^\\s@]+@[^\\s@]+$", options: .regularExpression) != nil
            case .uri: return URLComponents(string: text)?.scheme?.isEmpty == false
            case .date:
                guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
                    return false
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.isLenient = false
                return formatter.date(from: text) != nil
            case .dateTime:
                return (try? Date(text, strategy: .iso8601)) != nil
                    || (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) != nil
            case .unknown: return false
            case nil: return true
            }
        case (.number(let schema), _):
            let number: Double
            switch value {
            case .int(let v): number = Double(v);
            case .double(let v): number = v;
            default: return false
            }
            return number.isFinite && (schema.minimum.map { number >= $0 } ?? true)
                && (schema.maximum.map { number <= $0 } ?? true)
        case (.integer(let schema), _):
            let number: Int64
            switch value {
            case .int(let value): number = value
            case .double(let value):
                guard let integer = Int64(exactly: value) else { return false }
                number = integer
            default: return false
            }
            return (schema.minimum.map { number >= $0 } ?? true) && (schema.maximum.map { number <= $0 } ?? true)
        case (.boolean, .bool): return true
        case (.multiSelect(let schema), .array(let values)):
            let choices: [String]
            switch schema.items {
            case .strings(let options): choices = options;
            case .titled(let options): choices = options.map(\.const);
            case .unknown: return false
            }
            let strings = values.compactMap { if case .string(let value) = $0 { value } else { nil } }
            return strings.count == values.count && Set(strings).count == strings.count
                && strings.allSatisfy(choices.contains) && (schema.minItems.map { strings.count >= $0 } ?? true)
                && (schema.maxItems.map { strings.count <= $0 } ?? true)
        default: return false
        }
    }
}
