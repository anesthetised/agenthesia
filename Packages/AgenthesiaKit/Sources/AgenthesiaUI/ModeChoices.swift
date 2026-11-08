import ACP
import SwiftUI

/// The content of the mode popover: one row per mode with its name and, under it, the agent's description, in the
/// agent's groups as sections. Arrow keys move the highlight, Return or a click chooses, Escape closes the popover.
struct ModeChoices: View {
    let choices: ACP.ConfigSelectOptions
    let selected: ACP.ConfigValueID?
    let onSelect: (ACP.ConfigValueID) -> Void
    @State private var highlighted: ACP.ConfigValueID?

    /// What VoiceOver reads for a row.
    static func label(of choice: ACP.ConfigSelectOption) -> String {
        [choice.name, choice.description].compactMap(\.self).joined(separator: ". ")
    }

    static let width: CGFloat = 320
    static let maxHeight: CGFloat = 360

    /// The list's height: each row at its own height (a description makes it taller), a header per group and the
    /// list's padding, at most `maxHeight`; a longer list scrolls.
    static func height(of choices: ACP.ConfigSelectOptions) -> CGFloat {
        var sections = 0
        if case .grouped(let groups) = choices { sections = groups.count }
        let rows = choices.allOptions.reduce(0) { $0 + ($1.description == nil ? plainRowHeight : describedRowHeight) }
        return min(rows + CGFloat(sections) * sectionHeaderHeight + verticalPadding, maxHeight)
    }

    static let plainRowHeight: CGFloat = 24
    static let describedRowHeight: CGFloat = 39
    static let sectionHeaderHeight: CGFloat = 38
    static let verticalPadding: CGFloat = 20

    var body: some View {
        List(selection: $highlighted) {
            switch choices {
            case .flat(let options):
                rows(options)
            case .grouped(let groups):
                ForEach(groups, id: \.group) { group in
                    Section(group.name) { rows(group.options) }
                }
            }
        }
        .accessibilityLabel("Modes")
        .frame(width: Self.width, height: Self.height(of: choices))
        .onAppear { highlighted = selected }
        .onKeyPress(.return) {
            guard let highlighted else { return .ignored }
            onSelect(highlighted)
            return .handled
        }
    }

    private func rows(_ options: [ACP.ConfigSelectOption]) -> some View {
        ForEach(options, id: \.value) { choice in
            Button {
                onSelect(choice.value)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.name)
                        if let description = choice.description {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if choice.value == selected {
                        Image(systemName: "checkmark").accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .tag(choice.value)
            .accessibilityLabel(Self.label(of: choice))
            .accessibilityAddTraits(choice.value == selected ? .isSelected : [])
        }
    }
}
