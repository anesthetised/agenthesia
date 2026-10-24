import AgenthesiaCore
import SwiftUI

/// Why the merge failed; Git's output and conflicting paths are selectable.
struct MergeFailureView: View {
    let failure: SessionManager.MergeError
    let base: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch failure {
            case .conflicts(let paths):
                heading(failure.localizedDescription)
                output(paths.joined(separator: "\n"))
                Text(
                    "Ask the agent to merge \(base ?? "the base branch") into its branch and resolve the "
                        + "conflicts, then merge again."
                ).foregroundStyle(.secondary)
            case .failed(let output):
                heading("Git stopped the merge, and the project checkout was left as it was.")
                self.output(output)
            default:
                heading(failure.localizedDescription)
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
    }

    private func output(_ text: String) -> some View {
        ScrollView {
            Text(text).font(.callout.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
    }
}
