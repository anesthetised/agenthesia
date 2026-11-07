import AgenthesiaCore
import SwiftUI

/// The review in the file pane's slot (ADR-0041): what is compared, a native file list and the selected file's
/// diff. The same file invalidations refresh the list and the diff.
struct SessionReviewPane: View {
    @Bindable var review: SessionReview
    let files: SessionFiles
    let model: SessionWindowModel
    /// The pane's height; the file list takes at most a third of it.
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(review.baseBranch.map { "Changes against \($0)" } ?? "Session changes").font(.headline)
                    .lineLimit(1).truncationMode(.middle)
                WatchErrorNotice(files: files)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            Divider()
            if let error = review.error {
                ContentUnavailableView {
                    Label("Cannot Review Changes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error).textSelection(.enabled)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if review.isLoading {
                ProgressView("Checking changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if review.changes.isEmpty {
                ContentUnavailableView("No changes", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileList
                Divider()
                SessionReviewDetail(review: review, model: model, onEscape: close)
            }
            Divider()
            HStack {
                Button("Ask Agent", action: model.askAgent)
                    .disabled(!model.canAskAgent)
                    .help(model.askAgentHelp)
                Button("Merge…") { Task { await model.requestMerge() } }
                    .disabled(!model.canMerge)
                    .help(model.mergeHelp ?? "")
                Spacer()
                if !review.changes.isEmpty {
                    Text(review.viewedSummary)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }.padding(8)
        }
        .onExitCommand(perform: close)
        .task(id: files.indexRevision) { await review.refresh() }
    }

    private var fileList: some View {
        List(selection: $review.selectedPath) {
            ForEach(review.changes) { change in
                ReviewFileRow(
                    change: change,
                    lines: review.stats.files[change.path],
                    isBinary: review.stats.binary.contains(change.path),
                    isViewed: review.viewed.isViewed(change.path)
                ) { review.toggleViewed(change.path) }
                .tag(change.path)
            }
        }
        .accessibilityLabel("Changed files")
        // ponytail: estimated row heights, plus the list's top and bottom insets; a list of renames is cut a little
        // early, measure rows if that matters.
        .frame(height: min(CGFloat(review.changes.count) * 38 + 22, height / 3))
    }

    private func close() { model.showingReview = false }
}
