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
            ConfigSelectMenu(option: option, choices: choices, selected: current) { change(option.id, to: .select($0)) }
        case .boolean(let current):
            // A transactional binding intentionally keeps the confirmed value until the async write commits.
            Toggle(option.name, isOn: Binding(get: { current }, set: { change(option.id, to: .boolean($0)) }))
                .toggleStyle(.checkbox).fixedSize().help(option.description ?? option.name)
        case .unknown:
            EmptyView()
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
