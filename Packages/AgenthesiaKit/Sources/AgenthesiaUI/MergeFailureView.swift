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
                ).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .failed(let output):
                heading(SessionManager.MergeError.failedHeading)
                self.output(output)
            case .notRestored(let output):
                heading(SessionManager.MergeError.notRestoredHeading)
                self.output(output)
            default:
                heading(failure.localizedDescription)
            }
        }
    }

    private func heading(_ text: String) -> some View {
        // The sheet is sized before the failure appears; without this the text is cut off to fit.
        Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func output(_ text: String) -> some View {
        ScrollView {
            Text(text).font(.callout.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
    }
}
