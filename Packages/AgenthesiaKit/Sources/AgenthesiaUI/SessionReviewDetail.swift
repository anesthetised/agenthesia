import AgenthesiaCore
import Rendering
import SwiftUI

struct SessionReviewDetail: View {
    let review: SessionReview
    @State private var diff: String?

    private struct Selection: Equatable {
        let path: String?
        let revision: UUID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = review.selectedPath {
                Text(path).font(.headline).lineLimit(2).truncationMode(.middle).padding()
                Divider()
            }
            if let error = review.documentError {
                ContentUnavailableView {
                    Label("Cannot Preview Changes", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(error).textSelection(.enabled)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff {
                if diff.isEmpty {
                    ContentUnavailableView("No text changes", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    MarkdownPreview(text: diff).accessibilityLabel("File changes")
                }
            } else {
                ProgressView("Loading changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: Selection(path: review.selectedPath, revision: review.revision)) { await load() }
    }

    private func load() async {
        diff = nil
        await review.loadSelection()
        guard !Task.isCancelled, let document = review.document else { return }
        let rendered: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let hunks = UnifiedDiff.make(old: document.old, new: document.new)
                continuation.resume(
                    returning: hunks.isEmpty ? "" : LiveTranscriptSource.fenced(hunks, language: "diff")
                )
            }
        }
        guard !Task.isCancelled else { return }
        diff = rendered
    }
}
