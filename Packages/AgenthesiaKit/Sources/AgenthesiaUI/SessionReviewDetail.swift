import AgenthesiaCore
import SwiftUI

/// The selected file's diff. A new diff replaces the shown one only once it is rendered, so nothing flickers.
struct SessionReviewDetail: View {
    let review: SessionReview
    let model: SessionWindowModel
    let onEscape: () -> Void
    @State private var diff: RenderedDiff?

    private struct Selection: Equatable {
        let path: String?
        let revision: UUID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = review.document?.path ?? review.selectedPath {
                HStack {
                    Text(path).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle).help(path)
                    Spacer(minLength: 8)
                    if review.isHolding {
                        HStack(spacing: 4) {
                            Text("File changed ·").foregroundStyle(.secondary)
                            Button("Show latest", action: review.showLatest).buttonStyle(.link)
                        }
                        .font(.callout).fixedSize()
                        .help("The diff stays while text is selected in it")
                    }
                }.padding(8)
                Divider()
            }
            if let error = review.documentError {
                ContentUnavailableView {
                    Label("Cannot Preview Changes", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(error).textSelection(.enabled)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff {
                if diff.lines.isEmpty {
                    ContentUnavailableView("No text changes", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ReviewDiffView(
                        diff: diff,
                        model: model,
                        onSelection: { review.hasSelection = $0 },
                        onEscape: onEscape
                    )
                }
            } else {
                ProgressView("Loading changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: Selection(path: review.selectedPath, revision: review.revision)) { await review.loadSelection() }
        .task(id: review.document) { await render() }
    }

    private func render() async {
        guard let document = review.document else { return }
        let rendered = await RenderedDiff.make(document)
        guard !Task.isCancelled else { return }
        diff = rendered
    }
}
