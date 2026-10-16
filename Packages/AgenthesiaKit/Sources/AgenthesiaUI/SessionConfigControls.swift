import ACP
import AgenthesiaCore
import SwiftUI

/// Displays only durable, agent-confirmed values, including adapter-normalized legacy modes.
struct SessionConfigControls: View {
    let session: SessionController
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(session.transcript.configOptions, id: \.id) { option in
                        control(option)
                            .help(option.description ?? option.name)
                    }
                    if session.isChangingConfig {
                        ProgressView().controlSize(.small).accessibilityLabel("Changing session settings")
                    }
                }
                .disabled(session.status != .idle || session.isChangingConfig)
            }
            .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
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
                Text("\(option.name): \(choices.allOptions.first { $0.value == current }?.name ?? current)")
            }
            .fixedSize()
        case .boolean(let current):
            // A transactional binding intentionally keeps the confirmed value until the async write commits.
            Toggle(option.name, isOn: Binding(get: { current }, set: { change(option.id, to: .boolean($0)) }))
                .toggleStyle(.checkbox).fixedSize()
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
        errorMessage = nil
        Task {
            do { try await session.setConfigOption(id, to: value) } catch {
                if session.status != .closed { errorMessage = String(describing: error) }
            }
        }
    }
}
