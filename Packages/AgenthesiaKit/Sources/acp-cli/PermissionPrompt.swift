import ACP
import Foundation

/// Asks the user to choose a permission option by number or by id.
enum PermissionPrompt {
    static func render(title: String, options: [ACP.PermissionOption]) -> String {
        let choices = options.enumerated().map { "  \($0.offset + 1)) \($0.element.name)" }
        return "\nPermission requested: \(title)\n" + choices.joined(separator: "\n") + "\nChoose: "
    }

    /// The outcome for `input`, or `nil` if it does not name an option.
    static func parse(_ input: String, options: [ACP.PermissionOption]) -> ACP.PermissionOutcome? {
        let input = input.trimmingCharacters(in: .whitespaces)
        if let number = Int(input), options.indices.contains(number - 1) {
            return .selected(options[number - 1].optionId)
        }
        if let option = options.first(where: { $0.optionId == input || $0.name.lowercased() == input.lowercased() }) {
            return .selected(option.optionId)
        }
        return nil
    }
}
