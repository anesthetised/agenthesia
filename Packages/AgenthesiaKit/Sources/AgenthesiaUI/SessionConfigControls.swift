import ACP
import AgenthesiaCore
import SwiftUI

/// Displays only durable, agent-confirmed values, including adapter-normalized legacy modes.
struct SessionConfigControls: View {
    let session: SessionController
    /// Called with the failure of a change, and with nil when the next change starts.
    var onError: (String?) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(session.transcript.configOptions, id: \.id) { option in
                    control(option)
                }
                if session.isChangingConfig {
                    ProgressView().controlSize(.small).accessibilityLabel("Changing session settings")
                }
            }
            .disabled(session.status != .idle || session.isChangingConfig)
        }
        .scrollIndicators(.never)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func control(_ option: ACP.ConfigOption) -> some View {
        switch option.value {
        case .select(let current, let choices):
            Menu {
                switch choices {
                case .flat(let options):
                    choiceButtons(options, selected: current, option: option)
                case .grouped(let groups):
                    ForEach(groups, id: \.group) { group in
                        Section(group.name) {
                            choiceButtons(group.options, selected: current, option: option)
                        }
                    }
                }
            } label: {
                Text(choices.allOptions.first { $0.value == current }?.name ?? current)
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .accessibilityLabel(
                "\(option.name): \(choices.allOptions.first { $0.value == current }?.name ?? current)"
            )
            .help(option.description.map { "\(option.name): \($0)" } ?? option.name)
        case .boolean(let current):
            // A transactional binding intentionally keeps the confirmed value until the async write commits.
            Toggle(option.name, isOn: Binding(get: { current }, set: { change(option.id, to: .boolean($0)) }))
                .toggleStyle(.checkbox).fixedSize().help(option.description ?? option.name)
        case .unknown:
            EmptyView()
        }
    }

    private func choiceButtons(
        _ choices: [ACP.ConfigSelectOption],
        selected: String,
        option: ACP.ConfigOption
    ) -> some View {
        ForEach(choices, id: \.value) { choice in
            Button {
                change(option.id, to: .select(choice.value))
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

    private func change(_ id: ACP.ConfigOptionID, to value: ACP.ConfigValue) {
        onError(nil)
        Task {
            do { try await session.setConfigOption(id, to: value) } catch {
                if session.status != .closed { onError(String(describing: error)) }
            }
        }
    }
}
