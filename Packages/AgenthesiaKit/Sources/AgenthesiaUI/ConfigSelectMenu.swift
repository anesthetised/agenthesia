import ACP
import SwiftUI

/// The pill menu of a select option, shared by a session's controls and the draft's hints (ADR-0040): the label is the
/// selected value only, and the option's name is in the tooltip and the accessibility label.
struct ConfigSelectMenu: View {
    let option: ACP.ConfigOption
    let choices: ACP.ConfigSelectOptions
    /// The value to mark, or nil when none is, as a draft's mode before one is picked.
    let selected: ACP.ConfigValueID?
    /// What the label reads while `selected` is nil.
    var placeholder = ""
    /// Replaces the option's description as the tooltip, and is added to the accessibility label.
    var note: String?
    let onSelect: (ACP.ConfigValueID) -> Void

    private var valueName: String {
        selected.map { value in choices.allOptions.first { $0.value == value }?.name ?? value } ?? placeholder
    }

    var accessibilityText: String {
        ["\(option.name): \(valueName)", note].compactMap(\.self).joined(separator: ". ")
    }

    var body: some View {
        Menu {
            switch choices {
            case .flat(let options):
                choiceButtons(options)
            case .grouped(let groups):
                ForEach(groups, id: \.group) { group in
                    Section(group.name) { choiceButtons(group.options) }
                }
            }
        } label: {
            Text(valueName)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .accessibilityLabel(accessibilityText)
        .help(note ?? option.description.map { "\(option.name): \($0)" } ?? option.name)
    }

    private func choiceButtons(_ options: [ACP.ConfigSelectOption]) -> some View {
        ForEach(options, id: \.value) { choice in
            Button {
                onSelect(choice.value)
            } label: {
                if choice.value == selected {
                    Label(choice.name, systemImage: "checkmark")
                } else {
                    Text(choice.name)
                }
            }
            .help(choice.description ?? choice.name)
        }
    }
}
