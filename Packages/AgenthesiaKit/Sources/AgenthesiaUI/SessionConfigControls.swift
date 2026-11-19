import ACP
import AgenthesiaCore
import SwiftUI

/// Displays only durable, agent-confirmed values, including adapter-normalized legacy modes, and beside them the changes
/// picked during a turn for the next one (ADR-0019's amendment).
struct SessionConfigControls: View {
    let session: SessionController

    var body: some View {
        ConfigControlRow(
            options: session.transcript.configOptions,
            pending: session.pendingConfig,
            modeNote: modeNote,
            isChanging: session.isChangingConfig,
            onChange: change
        )
        .disabled(![.idle, .running, .stopping].contains(session.status) || session.isChangingConfig)
    }

    /// Added to the mode pill's help while a permission request waits: the change does not answer it.
    var modeNote: String? {
        session.pendingPermissions.isEmpty ? nil : "Changing the mode does not answer the waiting request."
    }

    /// The controller keeps the failure as `configError`.
    func change(_ id: ACP.ConfigOptionID, to value: ACP.ConfigValue) {
        Task { try? await session.setConfigOption(id, to: value) }
    }
}
