import ACP
import AgenthesiaCore
import SwiftUI

/// The composer's settings pills, one row for a session's options and the draft's hints (ADR-0019, ADR-0040): a select
/// option is a `ConfigSelectMenu`, a boolean a toggle pill. Options that do not fit move into a `…` menu, so no pill is
/// cut by the card's edge; `ViewThatFits` shows the first split that fits (`split(_:overflowing:)`).
struct ConfigControlRow: View {
    /// The options in the agent's order; options of unknown types are not shown.
    let options: [ACP.ConfigOption]
    /// Values a session applies from the next turn, shown after the confirmed ones (`High → Max, next turn`).
    var pending: [ACP.ConfigOptionID: ACP.ConfigValue] = [:]
    /// The select value a pill marks, nil when none is (a draft's mode before one is picked).
    var selected: (ACP.ConfigOption) -> ACP.ConfigValueID? = Self.currentValue
    /// What a select pill reads while its value is nil.
    var placeholder = ""
    /// The select pills' tooltip and accessibility note (`ConfigSelectMenu.note`).
    var note: String?
    /// A sentence added to the mode pill's tooltip and accessibility label.
    var modeNote: String?
    /// A change is pending: a spinner follows the pills.
    var isChanging = false
    let onChange: (ACP.ConfigOptionID, ACP.ConfigValue) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = options.filter(Self.isShown)
        ViewThatFits(in: .horizontal) {
            ForEach(0...shown.count, id: \.self) { count in
                row(Self.split(shown, overflowing: count))
            }
        }
        // `ViewThatFits` re-measures the splits it does not show only when its size changes, so a label that shrank
        // (a pending change applied or dropped) would leave pills in `…`; new labels make a new layout.
        .id(shown.map(title))
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: shown.map(\.id))
    }

    /// The pills and the `…` menu's options when `count` options overflow: the others leave from the end first, then
    /// mode, model and effort, also from the end. Both keep the agent's order.
    static func split(
        _ options: [ACP.ConfigOption],
        overflowing count: Int
    ) -> (shown: [ACP.ConfigOption], overflow: [ACP.ConfigOption]) {
        let fromEnd = options.indices.reversed()
        let leaving = Set(
            (fromEnd.filter { !isPrimary(options[$0]) } + fromEnd.filter { isPrimary(options[$0]) }).prefix(count)
        )
        return (
            options.indices.filter { !leaving.contains($0) }.map { options[$0] },
            leaving.sorted().map { options[$0] }
        )
    }

    nonisolated static func currentValue(of option: ACP.ConfigOption) -> ACP.ConfigValueID? {
        if case .select(let value, _) = option.value { value } else { nil }
    }

    private static func isPrimary(_ option: ACP.ConfigOption) -> Bool {
        option.category == .mode || option.category == .model || option.category == .thoughtLevel
    }

    private static func isShown(_ option: ACP.ConfigOption) -> Bool {
        if case .unknown = option.value { false } else { true }
    }

    private func row(_ split: (shown: [ACP.ConfigOption], overflow: [ACP.ConfigOption])) -> some View {
        HStack(spacing: 2) {
            ForEach(split.shown, id: \.id) { pill($0).transition(.opacity) }
            if !split.overflow.isEmpty { more(split.overflow) }
            if isChanging { ProgressView().controlSize(.small).accessibilityLabel("Changing session settings") }
        }
        .fixedSize()
    }

    @ViewBuilder private func pill(_ option: ACP.ConfigOption) -> some View {
        switch option.value {
        case .select(_, let choices):
            ConfigSelectMenu(
                option: option,
                choices: choices,
                selected: selected(option),
                pending: pendingName(option),
                placeholder: placeholder,
                note: note,
                addendum: option.category == .mode ? modeNote : nil
            ) { onChange(option.id, .select($0)) }
        case .boolean(let isOn):
            Toggle(toggleTitle(option), isOn: binding(option, isOn))
                .toggleStyle(PillToggleStyle()).help(option.description ?? option.name)
        case .unknown:
            EmptyView()
        }
    }

    /// The overflowing options with their values; a boolean is a checkable item.
    private func more(_ options: [ACP.ConfigOption]) -> some View {
        Menu {
            ForEach(options, id: \.id) { option in
                switch option.value {
                case .select(_, let choices):
                    let value = ConfigSelectMenu.valueName(of: selected(option), in: choices) ?? placeholder
                    Menu("\(option.name): \(ConfigSelectMenu.label(value, pending: pendingName(option)))") {
                        ConfigChoiceItems(choices: choices, selected: selected(option)) {
                            onChange(option.id, .select($0))
                        }
                    }
                case .boolean(let isOn):
                    Toggle(toggleTitle(option), isOn: binding(option, isOn))
                case .unknown:
                    EmptyView()
                }
            }
        } label: {
            Text("…")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More settings")
        .help("More settings")
    }

    /// A transactional binding: it keeps the confirmed value until the agent's answer has been recorded (ADR-0019).
    /// A click flips the pending value when there is one, so a second click drops it.
    private func binding(_ option: ACP.ConfigOption, _ isOn: Bool) -> Binding<Bool> {
        Binding(
            get: { isOn },
            set: { _ in onChange(option.id, .boolean(Self.toggled(isOn, pending: pending[option.id]))) }
        )
    }

    /// The value a click on a toggle asks for: the opposite of the pending value, or of the confirmed one.
    static func toggled(_ isOn: Bool, pending: ACP.ConfigValue?) -> Bool {
        if case .boolean(let wanted) = pending { !wanted } else { !isOn }
    }

    private func pendingName(_ option: ACP.ConfigOption) -> String? {
        pending[option.id].map(option.valueName)
    }

    private func toggleTitle(_ option: ACP.ConfigOption) -> String {
        ConfigSelectMenu.label(option.name, pending: pendingName(option))
    }

    /// What the option's pill reads.
    private func title(_ option: ACP.ConfigOption) -> String {
        guard case .select(_, let choices) = option.value else { return toggleTitle(option) }
        let value = ConfigSelectMenu.valueName(of: selected(option), in: choices) ?? placeholder
        return ConfigSelectMenu.label(value, pending: pendingName(option))
    }
}

/// A boolean option as a pill: its name, tinted on a filled capsule while on.
private struct PillToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(
                    configuration.isOn ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear),
                    in: .capsule
                )
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
