import AgenthesiaCore
import SwiftUI

/// A session error as a short sentence with the actions that fit it and the raw text under Details, in the
/// transcript column.
struct FailureBanner: View {
    let failure: SessionFailure
    /// The actions the caller can perform; the others are left out.
    let offering: Set<SessionFailure.Action>
    let perform: (SessionFailure.Action) -> Void
    @State private var showsDetails = false

    init(_ stored: String, offering: Set<SessionFailure.Action>, perform: @escaping (SessionFailure.Action) -> Void) {
        failure = SessionFailure(stored)
        self.offering = offering
        self.perform = perform
    }

    /// The failure's actions that the caller offers.
    var actions: [SessionFailure.Action] { failure.actions.filter(offering.contains) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.summary, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red).textSelection(.enabled)
            if !actions.isEmpty {
                HStack {
                    ForEach(actions, id: \.self) { action in
                        switch action {
                        case .agentLog: Button("Agent Log") { perform(action) }
                        case .newSession: Button("New Session") { perform(action) }
                        case .manageAgents: SettingsLink { Text("Manage Agents…") }
                        }
                    }
                }
            }
            if let details = failure.details {
                DisclosureGroup("Details", isExpanded: $showsDetails) {
                    Text(details).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .font(.caption)
        .frame(maxWidth: TranscriptColumn.maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}
