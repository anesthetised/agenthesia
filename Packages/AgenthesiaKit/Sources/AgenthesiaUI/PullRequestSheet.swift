import AgenthesiaCore
import SwiftUI

struct PullRequestSheet: View {
    @Bindable var draft: PullRequestDraft
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Pull Request").font(.headline)
            Text("\(draft.target.branch) into \(draft.target.base) on \(draft.target.remote)")
                .foregroundStyle(.secondary).textSelection(.enabled)
            TextField("Title", text: $draft.title).disabled(draft.isRunning)
            Text("Description").font(.subheadline)
            // Return adds a line here, as in the merge sheet's message.
            TextEditor(text: $draft.body)
                .font(.body)
                .frame(minHeight: 120)
                .accessibilityLabel("Description")
                .disabled(draft.isRunning)
            if let current = draft.step {
                ForEach(SessionManager.PullRequestStep.allCases, id: \.self) { step in
                    StepRow(
                        text: draft.label(of: step),
                        state: step < current
                            ? .done
                            : step > current
                                ? .pending
                                : draft.failure != nil ? .failed : .running
                    )
                }
            }
            if let failure = draft.failure {
                // Git's and gh's output can be long.
                ScrollView {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(draft.isRunning)
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canCreate)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(draft.isRunning)
    }

    private struct StepRow: View {
        enum State { case done, running, failed, pending }
        let text: String
        let state: State

        var body: some View {
            HStack(spacing: 6) {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .running: ProgressView().controlSize(.small)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                }
                Text(text).foregroundStyle(state == .pending ? .secondary : .primary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(Self.value(state))
        }

        static func value(_ state: State) -> String {
            switch state {
            case .done: "Done"
            case .running: "In progress"
            case .failed: "Failed"
            case .pending: "Not started"
            }
        }
    }
}
