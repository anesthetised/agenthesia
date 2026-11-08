import ACP
import SwiftUI

/// The composer's settings pills, one row for a session's options and the draft's hints (ADR-0019, ADR-0040): a select
/// option is a `ConfigSelectMenu`, a boolean a toggle pill. Options that do not fit move into a `…` menu, so no pill is
/// cut by the card's edge; `ViewThatFits` shows the first split that fits (`split(_:overflowing:)`).
struct ConfigControlRow: View {
    /// The options in the agent's order; options of unknown types are not shown.
    let options: [ACP.ConfigOption]
    /// The select value a pill marks, nil when none is (a draft's mode before one is picked).
    var selected: (ACP.ConfigOption) -> ACP.ConfigValueID? = Self.currentValue
    /// What a select pill reads while its value is nil.
    var placeholder = ""
    /// The select pills' tooltip and accessibility note (`ConfigSelectMenu.note`).
    var note: String?
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
                placeholder: placeholder,
                note: note
            ) { onChange(option.id, .select($0)) }
        case .boolean(let isOn):
            Toggle(option.name, isOn: binding(option, isOn))
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
                    Menu("\(option.name): \(value)") {
                        ConfigChoiceItems(choices: choices, selected: selected(option)) {
                            onChange(option.id, .select($0))
                        }
                    }
                case .boolean(let isOn):
                    Toggle(option.name, isOn: binding(option, isOn))
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
    private func binding(_ option: ACP.ConfigOption, _ isOn: Bool) -> Binding<Bool> {
        Binding(get: { isOn }, set: { onChange(option.id, .boolean($0)) })
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
