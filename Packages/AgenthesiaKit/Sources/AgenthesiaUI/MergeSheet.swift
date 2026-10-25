import AgenthesiaCore
import SwiftUI

struct MergeSheet: View {
    @Bindable var request: MergeRequest
    let onMerge: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            switch request.check {
            case nil:
                ProgressView("Checking the merge…").controlSize(.small)
            case .blocked(let explanation):
                Label(explanation, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .ready(let base, let files, let commits):
                Text(Self.summary(base: base, files: files, commits: commits)).foregroundStyle(.secondary)
            }
            if !request.isBlocked {
                Text("Commit message").font(.subheadline)
                // Return adds a line here; a vertical TextField would submit and press Merge.
                TextEditor(text: $request.message)
                    .font(.body)
                    .frame(minHeight: 90)
                    .accessibilityLabel("Commit message")
                    .disabled(request.isMerging)
            }
            if let failure = request.failure { MergeFailureView(failure: failure, base: request.session.baseBranch) }
            HStack {
                if request.isMerging {
                    ProgressView().controlSize(.small)
                    Text("Merging…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(request.isMerging)
                if !request.isBlocked {
                    Button("Merge", action: onMerge)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!request.canMerge)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(request.isMerging)
    }

    static func summary(base: String, files: Int, commits: Int) -> String {
        let changed = files == 1 ? "1 changed file" : "\(files) changed files"
        let commits = commits == 1 ? "1 commit" : "\(commits) commits"
        return "\(changed) and \(commits) become one commit on \(base). Uncommitted changes are included."
    }
}
