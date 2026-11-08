import ACP
import AgenthesiaCore
import SwiftUI

/// Displays only durable, agent-confirmed values, including adapter-normalized legacy modes.
struct SessionConfigControls: View {
    let session: SessionController
    /// Called with the failure of a change, and with nil when the next change starts.
    var onError: (String?) -> Void = { _ in }

    var body: some View {
        ConfigControlRow(
            options: session.transcript.configOptions,
            isChanging: session.isChangingConfig,
            onChange: change
        )
        .disabled(session.status != .idle || session.isChangingConfig)
    }

    func change(_ id: ACP.ConfigOptionID, to value: ACP.ConfigValue) {
        onError(nil)
        Task {
            do { try await session.setConfigOption(id, to: value) } catch {
                if session.status != .closed { onError(String(describing: error)) }
            }
        }
    }
}
