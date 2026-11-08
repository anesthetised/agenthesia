import ACP
import SwiftUI

/// The pill menu of a select option, shared by a session's controls and the draft's hints (ADR-0040): the label is the
/// selected value only, and the option's name is in the tooltip and the accessibility label. The mode opens a
/// popover with the agent's descriptions instead of a menu (`ModeChoices`).
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
    @State private var isPresented = false

    private var valueName: String { Self.valueName(of: selected, in: choices) ?? placeholder }

    /// The name of `value` among `choices`, the value itself when the agent does not list it.
    static func valueName(of value: ACP.ConfigValueID?, in choices: ACP.ConfigSelectOptions) -> String? {
        value.map { value in choices.allOptions.first { $0.value == value }?.name ?? value }
    }

    var accessibilityText: String {
        ["\(option.name): \(valueName)", note].compactMap(\.self).joined(separator: ". ")
    }

    var body: some View {
        if option.category == .mode { modeButton } else { menu }
    }

    private var tooltip: String { note ?? option.description.map { "\(option.name): \($0)" } ?? option.name }

    private var modeButton: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 3) {
                Text(valueName)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small).accessibilityHidden(true)
            }
        }
        .buttonStyle(.borderless).fixedSize()
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ModeChoices(choices: choices, selected: selected) { value in
                isPresented = false
                onSelect(value)
            }
        }
        .accessibilityLabel(accessibilityText)
        .help(tooltip)
    }

    private var menu: some View {
        Menu {
            ConfigChoiceItems(choices: choices, selected: selected, onSelect: onSelect)
        } label: {
            Text(valueName)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .accessibilityLabel(accessibilityText)
        .help(tooltip)
    }
}

/// The items of a select option's menu: the agent's choices, in its groups as sections, with a checkmark on the
/// selected one and each choice's description as its tooltip.
struct ConfigChoiceItems: View {
    let choices: ACP.ConfigSelectOptions
    let selected: ACP.ConfigValueID?
    let onSelect: (ACP.ConfigValueID) -> Void

    var body: some View {
        switch choices {
        case .flat(let options):
            buttons(options)
        case .grouped(let groups):
            ForEach(groups, id: \.group) { group in
                Section(group.name) { buttons(group.options) }
            }
        }
    }

    private func buttons(_ options: [ACP.ConfigSelectOption]) -> some View {
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
